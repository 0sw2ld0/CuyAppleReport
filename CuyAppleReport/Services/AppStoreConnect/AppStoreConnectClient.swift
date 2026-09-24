import Foundation

struct ASCApp: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let bundleId: String
}

struct ASCFeedback: Sendable {
    let id: String
    let kind: String
    let comment: String?
    let testerEmail: String?
    let testerName: String?
    let deviceModel: String?
    let deviceFamily: String?
    let osVersion: String?
    let locale: String?
    let timeZone: String?
    let batteryPercentage: Int?
    let connectionType: String?
    let appVersion: String?
    let buildId: String?
    let buildNumber: String?
    let createdDate: Date
    let screenshotURLs: [URL]
    let crashLog: String?
    let rawJSON: Data?
}

private struct ASCResource: Sendable {
    let id: String
    let attributes: [String: String]
    let buildId: String?
    let testerEmail: String?
    let testerName: String?
    let deviceFamily: String?
    let batteryPercentage: Int?
    let buildAttributes: [String: String]
    let screenshotURLs: [URL]
    let rawJSON: Data?
}

enum ASCError: LocalizedError {
    case invalidResponse
    case http(Int, String?)
    case network
    case pagination
    case sessionExpired
    case teamSwitchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Apple devolvió una respuesta que no se pudo leer."
        case .http(401, _): "Issuer ID, Key ID o clave privada incorrectos."
        case .http(403, _): "La key no tiene permisos suficientes. Usa el rol App Manager, Admin o Developer."
        case .http(429, _): "Apple limitó temporalmente las solicitudes. Intenta de nuevo en un momento."
        case .http(let code, let detail): detail ?? "App Store Connect respondió con HTTP \(code)."
        case .network: "No se pudo contactar a Apple. Comprueba la conexión a internet."
        case .pagination: "Apple devolvió un enlace de paginación no válido."
        case .sessionExpired: "Tu sesión de App Store Connect expiró. Vuelve a iniciar sesión."
        case .teamSwitchFailed(let team): "No se pudo cambiar al equipo “\(team)”. Cámbialo desde “Abrir App Store Connect…” en Ajustes."
        }
    }
}

actor AppStoreConnectClient {
    private let transport: any ASCTransport
    private var appVersionByBuild: [String: String] = [:]

    init(transport: any ASCTransport) {
        self.transport = transport
    }

    init(tokenProvider: AppleTokenProvider, session: URLSession = .shared) {
        self.init(transport: APIKeyTransport(tokenProvider: tokenProvider, session: session))
    }

    func fetchApps() async throws -> [ASCApp] {
        var apps: [ASCApp] = []
        for try await resource in resources(startingAt: "/v1/apps?limit=200&sort=name") {
            apps.append(ASCApp(id: resource.id, name: resource.attributes["name"] ?? "App sin nombre",
                               bundleId: resource.attributes["bundleId"] ?? ""))
        }
        return apps
    }

    func fetchFeedback(appId: String, kind: String, since: Date? = nil) async throws -> [ASCFeedback] {
        let endpoint = kind == "Comentario" ? "betaFeedbackScreenshotSubmissions" : "betaFeedbackCrashSubmissions"
        let path = "/v1/apps/\(appId)/\(endpoint)?limit=200&include=build,tester&sort=-createdDate"
        var result: [ASCFeedback] = []
        let cutoff = since?.addingTimeInterval(-60 * 60)
        for try await resource in resources(startingAt: path) {
            let attributes = resource.attributes
            if let cutoff, let createdDate = Self.date(attributes["createdDate"]), createdDate < cutoff { break }
            let id = resource.id
            result.append(ASCFeedback(
                id: id, kind: kind,
                comment: attributes["comment"],
                testerEmail: attributes["email"] ?? resource.testerEmail,
                testerName: resource.testerName,
                deviceModel: attributes["deviceModel"],
                deviceFamily: resource.deviceFamily,
                osVersion: attributes["osVersion"],
                locale: attributes["locale"],
                timeZone: attributes["timeZone"],
                batteryPercentage: resource.batteryPercentage,
                connectionType: attributes["connectionType"],
                appVersion: nil,
                buildId: resource.buildId,
                buildNumber: resource.buildAttributes["version"],
                createdDate: Self.date(attributes["createdDate"]) ?? .now,
                screenshotURLs: kind == "Comentario" ? resource.screenshotURLs : [],
                crashLog: nil,
                rawJSON: resource.rawJSON
            ))
        }

        for index in result.indices {
            guard let buildId = result[index].buildId else { continue }
            result[index] = result[index].withAppVersion(await appVersion(forBuild: buildId))
        }

        if kind == "Error", !result.isEmpty {
            let ids = result.map(\.id)
            let logURLs = ids.map(crashLogPath(for:))
            let logs = await withTaskGroup(of: (Int, String?).self, returning: [String?].self) { group in
                var output = Array<String?>(repeating: nil, count: ids.count)
                var next = 0
                for _ in 0..<min(4, ids.count) {
                    let index = next
                    next += 1
                    group.addTask { (index, try? await self.fetchCrashLog(at: logURLs[index])) }
                }
                while let (index, log) = await group.next() {
                    output[index] = log
                    if next < ids.count {
                        let pending = next
                        next += 1
                        group.addTask { (pending, try? await self.fetchCrashLog(at: logURLs[pending])) }
                    }
                }
                return output
            }
            for index in result.indices { result[index] = result[index].withCrashLog(logs[index]) }
        }
        return result
    }

    /// Log de un crash concreto (para reintentar los que no se pudieron descargar antes).
    func fetchCrashLog(submissionId: String) async throws -> String? {
        try await fetchCrashLog(at: crashLogPath(for: submissionId))
    }

    fileprivate func fetchCrashLog(at path: String) async throws -> String? {
        let data = try await transport.get(path)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let attributes = (root?["data"] as? [String: Any])?["attributes"] as? [String: Any]
        return attributes?["logText"] as? String
    }

    private func crashLogPath(for id: String) -> String {
        "/v1/betaFeedbackCrashSubmissions/\(id)/crashLog?fields%5BbetaCrashLogs%5D=logText"
    }

    /// Versión de la app (ej. "1.2") de una build. `include` anidado no funciona en `/iris`,
    /// así que se pide cada build una vez y se guarda en caché.
    private func appVersion(forBuild buildId: String) async -> String? {
        if let cached = appVersionByBuild[buildId] { return cached }
        let path = "/v1/builds/\(buildId)?include=preReleaseVersion&fields%5Bbuilds%5D=version,preReleaseVersion&fields%5BpreReleaseVersions%5D=version"
        guard let data = try? await transport.get(path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let preRelease = (root["included"] as? [[String: Any]] ?? []).first { ($0["type"] as? String) == "preReleaseVersions" }
        let version = (preRelease?["attributes"] as? [String: Any])?["version"] as? String
        if let version { appVersionByBuild[buildId] = version }
        return version
    }

    private func resources(startingAt firstPath: String) -> AsyncThrowingStream<ASCResource, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var nextPath: String? = firstPath
                    while let path = nextPath {
                        let data = try await self.transport.get(path)
                        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw ASCError.invalidResponse
                        }
                        let included = root["included"] as? [[String: Any]] ?? []
                        for resource in root["data"] as? [[String: Any]] ?? [] {
                            guard let id = resource["id"] as? String, !id.isEmpty else { continue }
                            let attributes = Self.stringDictionary(resource["attributes"] as? [String: Any] ?? [:])
                            let relationship = (resource["relationships"] as? [String: Any])?["build"] as? [String: Any]
                            let buildId = (relationship?["data"] as? [String: Any])?["id"] as? String
                            let build = included.first { ($0["id"] as? String) == buildId }
                            let buildAttributes = Self.stringDictionary(build?["attributes"] as? [String: Any] ?? [:])
                            let testerRelationship = (resource["relationships"] as? [String: Any])?["tester"] as? [String: Any]
                            let testerId = (testerRelationship?["data"] as? [String: Any])?["id"] as? String
                            let tester = included.first { ($0["id"] as? String) == testerId }
                            let testerAttributes = tester?["attributes"] as? [String: Any] ?? [:]
                            let testerName = [testerAttributes["firstName"] as? String, testerAttributes["lastName"] as? String]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                            let rawJSON = try? JSONSerialization.data(withJSONObject: resource, options: [.fragmentsAllowed])
                            continuation.yield(ASCResource(
                                id: id, attributes: attributes, buildId: buildId,
                                testerEmail: testerAttributes["email"] as? String,
                                testerName: testerName.isEmpty ? nil : testerName,
                                deviceFamily: attributes["deviceFamily"],
                                batteryPercentage: resource["attributes"].flatMap { ($0 as? [String: Any])?["batteryPercentage"] as? Int },
                                buildAttributes: buildAttributes,
                                screenshotURLs: Self.urls(in: (resource["attributes"] as? [String: Any])?["screenshots"]),
                                rawJSON: rawJSON))
                        }
                        if let link = (root["links"] as? [String: Any])?["next"] as? String, !link.isEmpty {
                            guard let next = self.transport.relativePath(fromNextLink: link) else {
                                throw ASCError.pagination
                            }
                            nextPath = next
                        } else {
                            nextPath = nil
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func stringDictionary(_ values: [String: Any]) -> [String: String] {
        values.compactMapValues { $0 as? String }
    }

    private static func urls(in value: Any?) -> [URL] {
        var found: [URL] = []
        func visit(_ value: Any) {
            if let string = value as? String, let url = URL(string: string),
               ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
               (url.pathExtension.lowercased() == "png" || url.pathExtension.lowercased() == "jpg" || url.host != nil) {
                found.append(url)
            } else if let dictionary = value as? [String: Any] {
                for (key, value) in dictionary where ["url", "downloadUrl", "imageUrl"].contains(key) { visit(value) }
                if found.isEmpty { for value in dictionary.values { visit(value) } }
            } else if let array = value as? [Any] {
                array.forEach(visit)
            }
        }
        if let value { visit(value) }
        // Sin duplicados y en el orden en que las envió el tester.
        var seen = Set<URL>()
        return found.filter { seen.insert($0).inserted }
    }
}

private extension ASCFeedback {
    func withCrashLog(_ log: String?) -> ASCFeedback {
        copy(appVersion: appVersion, crashLog: log)
    }

    func withAppVersion(_ version: String?) -> ASCFeedback {
        copy(appVersion: version, crashLog: crashLog)
    }

    func copy(appVersion: String?, crashLog: String?) -> ASCFeedback {
        ASCFeedback(id: id, kind: kind, comment: comment, testerEmail: testerEmail,
                    testerName: testerName, deviceModel: deviceModel, deviceFamily: deviceFamily,
                    osVersion: osVersion, locale: locale, timeZone: timeZone,
                    batteryPercentage: batteryPercentage, connectionType: connectionType,
                    appVersion: appVersion, buildId: buildId, buildNumber: buildNumber, createdDate: createdDate,
                    screenshotURLs: screenshotURLs, crashLog: crashLog, rawJSON: rawJSON)
    }
}
