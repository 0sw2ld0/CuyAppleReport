import Foundation
import OSLog
import SwiftData

@MainActor
enum SyncService {
    /// Crea el cliente según el modo de la conexión. En modo sesión verifica la sesión
    /// y activa el equipo configurado antes de devolverlo.
    static func makeClient(for connection: Connection) async throws -> AppStoreConnectClient {
        switch connection.authMode {
        case .apiKey:
            let pemData = try KeychainStore.load(account: connection.keyId)
            let provider = try AppleTokenProvider(issuerId: connection.issuerId, keyId: connection.keyId, pemData: pemData)
            return AppStoreConnectClient(tokenProvider: provider)
        case .webSession:
            let transport = WebSessionTransport(connectionId: connection.id)
            var session = try await transport.session()
            if let teamId = connection.teamId, session.team?.id != teamId,
               let team = (connection.teams + session.teams).first(where: { $0.id == teamId }) {
                session = try await transport.switchTeam(to: team)
            }
            connection.apply(session)
            return AppStoreConnectClient(transport: transport)
        }
    }

    static func synchronize(connection: Connection, context: ModelContext,
                            progress report: (SyncProgress) -> Void = { _ in }) async throws -> Int {
        var progress = SyncProgress()
        report(progress)
        let client = try await makeClient(for: connection)
        let selectedApps = connection.apps.filter(\.isMonitored)
        progress.appCount = selectedApps.count
        var totalNew = 0

        for (index, app) in selectedApps.enumerated() {
            progress.appIndex = index
            progress.appName = app.name
            progress.imagesDone = 0
            progress.imagesTotal = 0
            let run = SyncRun(appleAppId: app.appleId)
            context.insert(run)
            do {
                for kind in ["Comentario", "Error"] {
                    progress.phase = kind == "Comentario" ? .comments : .crashes
                    report(progress)
                    let remoteItems = try await client.fetchFeedback(appId: app.appleId, kind: kind, since: app.lastSyncAt)
                    progress.found += remoteItems.count
                    let existingItems = try context.fetch(FetchDescriptor<Feedback>())
                    let byID = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.appleId, $0) })

                    // Solo se descargan las capturas que no están ya guardadas en disco.
                    let needsImages = remoteItems.filter { kind == "Comentario" && !hasLocalScreenshots(byID[$0.id], expected: $0.screenshotURLs.count) }
                    progress.imagesTotal += needsImages.reduce(0) { $0 + $1.screenshotURLs.count }
                    let needsImageIDs = Set(needsImages.map(\.id))
                    if !needsImages.isEmpty {
                        progress.phase = .images
                        report(progress)
                    }

                    for remote in remoteItems {
                        var screenshotPaths: [String] = []
                        if needsImageIDs.contains(remote.id) {
                            screenshotPaths = await saveScreenshots(remote.screenshotURLs, submissionId: remote.id)
                            progress.imagesDone += remote.screenshotURLs.count
                            report(progress)
                        }
                        var crashPath: String?
                        if let log = remote.crashLog, let path = try? FileStore.saveCrashLog(log, submissionId: remote.id) {
                            crashPath = path.path
                        }
                        if let existing = byID[remote.id] {
                            existing.comment = remote.comment
                            existing.testerEmail = remote.testerEmail
                            existing.testerName = remote.testerName
                            existing.deviceModel = remote.deviceModel
                            existing.deviceFamily = remote.deviceFamily
                            existing.osVersion = remote.osVersion
                            existing.locale = remote.locale
                            existing.timeZone = remote.timeZone
                            existing.batteryPercentage = remote.batteryPercentage
                            existing.connectionType = remote.connectionType
                            existing.appVersion = remote.appVersion ?? existing.appVersion
                            existing.buildNumber = remote.buildNumber
                            existing.createdDate = remote.createdDate
                            if !screenshotPaths.isEmpty { existing.screenshotPaths = screenshotPaths }
                            if let crashPath { existing.crashLogPath = crashPath }
                            existing.rawJSON = remote.rawJSON
                        } else {
                            let feedback = Feedback(appleId: remote.id, kind: kind, comment: remote.comment,
                                testerEmail: remote.testerEmail, testerName: remote.testerName,
                                deviceModel: remote.deviceModel, deviceFamily: remote.deviceFamily,
                                osVersion: remote.osVersion, locale: remote.locale, timeZone: remote.timeZone,
                                batteryPercentage: remote.batteryPercentage, connectionType: remote.connectionType,
                                appVersion: remote.appVersion, buildNumber: remote.buildNumber,
                                createdDate: remote.createdDate, screenshotPaths: screenshotPaths,
                                crashLogPath: crashPath, rawJSON: remote.rawJSON, app: app)
                            context.insert(feedback)
                            run.newItems += 1
                            totalNew += 1
                            progress.newItems = totalNew
                            report(progress)
                        }
                    }
                }
                // Testers y grupos: si falla (p. ej. por permisos), no interrumpe la sincronización del feedback.
                progress.phase = .testers
                report(progress)
                do {
                    try await syncTesters(app: app, client: client, context: context)
                } catch {
                    logger.error("Testers de \(app.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }

                // Reintenta los logs de errores que quedaron sin descargar en sincronizaciones anteriores.
                for crash in app.feedbacks where crash.kind == "Error" && crash.crashLogPath == nil {
                    if let log = try? await client.fetchCrashLog(submissionId: crash.appleId),
                       let path = try? FileStore.saveCrashLog(log, submissionId: crash.appleId) {
                        crash.crashLogPath = path.path
                    }
                }
                app.lastSyncAt = .now
                run.finishedAt = .now
                // Guardar por app: los elementos nuevos reciben su identificador definitivo cuanto antes.
                try context.save()
            } catch {
                run.errorMessage = error.localizedDescription
                run.finishedAt = .now
                try? context.save()
                throw error
            }
        }
        progress.phase = .saving
        report(progress)
        try context.save()
        return totalNew
    }

    private static let logger = Logger(subsystem: "com.cuycoders.CuyAppleReport", category: "sync")

    /// Grupos, testers (con su uso de 30 días) y última build de una app. Borra los que ya no existen.
    static func syncTesters(app: MonitoredApp, client: AppStoreConnectClient, context: ModelContext) async throws {
        let groups = try await client.fetchBetaGroups(appId: app.appleId)
        let testers = try await client.fetchBetaTesters(appId: app.appleId)
        let usage = (try? await client.fetchTesterUsage(appId: app.appleId)) ?? [:]
        if let latest = try? await client.fetchLatestBuild(appId: app.appleId) {
            app.latestVersion = latest.version
            app.latestBuild = latest.build
        }

        let existingGroups = Dictionary(app.betaGroups.map { ($0.groupId, $0) }, uniquingKeysWith: { first, _ in first })
        for group in groups {
            let record = existingGroups[group.id] ?? {
                let record = BetaGroupRecord(groupId: group.id, name: group.name, isInternal: group.isInternal, app: app)
                context.insert(record)
                return record
            }()
            record.name = group.name
            record.isInternal = group.isInternal
            record.publicLinkEnabled = group.publicLinkEnabled
            record.publicLinkLimit = group.publicLinkLimit
            record.feedbackEnabled = group.feedbackEnabled
            record.createdDate = group.createdDate
        }
        let groupIds = Set(groups.map(\.id))
        for stale in app.betaGroups where !groupIds.contains(stale.groupId) { context.delete(stale) }

        let internalIds = Set(groups.filter(\.isInternal).map(\.id))
        let externalIds = groupIds.subtracting(internalIds)
        let existingTesters = Dictionary(app.testers.map { ($0.testerId, $0) }, uniquingKeysWith: { first, _ in first })
        for tester in testers {
            let record = existingTesters[tester.id] ?? {
                let record = BetaTesterRecord(recordId: "\(app.appleId)|\(tester.id)", testerId: tester.id, app: app)
                context.insert(record)
                return record
            }()
            let appGroups = tester.groupIds.filter(groupIds.contains)
            record.email = tester.email
            record.firstName = tester.firstName
            record.lastName = tester.lastName
            record.stateRaw = tester.state
            record.inviteType = tester.inviteType
            record.installedVersion = tester.installedVersion
            record.installedBuild = tester.installedBuild
            record.installedDevice = tester.installedDevice
            record.installedOsVersion = tester.installedOsVersion
            record.numberOfInstalledDevices = tester.numberOfInstalledDevices
            record.devices = tester.devices
            record.groupIds = appGroups
            record.isInternal = appGroups.contains(where: internalIds.contains)
            record.isExternal = appGroups.contains(where: externalIds.contains) || tester.inviteType == "PUBLIC_LINK"
            record.lastModifiedDate = tester.lastModifiedDate
            let testerUsage = usage[tester.id]
            record.sessions30 = testerUsage?.sessions ?? 0
            record.crashes30 = testerUsage?.crashes ?? 0
            record.feedback30 = testerUsage?.feedback ?? 0
        }
        let testerIds = Set(testers.map(\.id))
        for stale in app.testers where !testerIds.contains(stale.testerId) { context.delete(stale) }
        app.testersSyncedAt = .now
    }

    /// Las capturas ya descargadas se reutilizan si están todas en disco.
    private static func hasLocalScreenshots(_ feedback: Feedback?, expected: Int) -> Bool {
        guard expected > 0 else { return true }
        guard let paths = feedback?.screenshotPaths, paths.count >= expected else { return false }
        return paths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    private static func saveScreenshots(_ urls: [URL], submissionId: String) async -> [String] {
        guard !urls.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, String?).self, returning: [String].self) { group in
            var paths = Array<String?>(repeating: nil, count: urls.count)
            var next = 0
            for _ in 0..<min(4, urls.count) {
                let index = next
                next += 1
                group.addTask {
                    let path = try? await FileStore.saveScreenshot(from: urls[index], submissionId: submissionId, index: index).path
                    return (index, path)
                }
            }
            while let (index, path) = await group.next() {
                paths[index] = path
                if next < urls.count {
                    let pending = next
                    next += 1
                    group.addTask {
                        let path = try? await FileStore.saveScreenshot(from: urls[pending], submissionId: submissionId, index: pending).path
                        return (pending, path)
                    }
                }
            }
            return paths.compactMap { $0 }
        }
    }
}
