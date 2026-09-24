import AppKit
import SwiftUI
import Combine
import Foundation
import SwiftData
import UserNotifications

enum AppPage: String, Hashable {
    case dashboard = "Dashboard"
    case comments = "Comentarios"
    case crashes = "Errores"
}

@MainActor
final class AppState: ObservableObject {
    @Published var page: AppPage = .dashboard
    @Published var selectedFeedbackId: String?
    @Published var selectedAppId: String?
    @Published var searchQuery = ""
    @Published var isSyncing = false
    @Published var syncMessage: String?
    @Published var errorMessage: String?
    @Published var selectedStatus = "Todos"
    @Published var syncProgress: SyncProgress?
    private var hideProgressTask: Task<Void, Never>?
    var modelContext: ModelContext?
    private var autoSyncTask: Task<Void, Never>?

    func startAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let minutes = self.firstConnection()?.effectiveSyncIntervalMinutes ?? 0
                do { try await Task.sleep(for: .seconds(minutes > 0 ? minutes * 60 : 60)) }
                catch { return }
                guard !Task.isCancelled else { return }
                // Con la sesión de Apple ID expirada no se hacen peticiones hasta volver a iniciar sesión.
                if minutes > 0, let connection = self.firstConnection(), connection.sessionState != .expired {
                    await self.sync(connection: connection)
                }
            }
        }
    }

    private func firstConnection() -> Connection? {
        guard let modelContext else { return nil }
        return try? modelContext.fetch(FetchDescriptor<Connection>()).first
    }

    func sync(connection: Connection) async {
        guard !isSyncing, let modelContext else { return }
        isSyncing = true
        errorMessage = nil
        syncMessage = "Sincronizando…"
        hideProgressTask?.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { syncProgress = SyncProgress() }
        defer { isSyncing = false }
        do {
            let count = try await SyncService.synchronize(connection: connection, context: modelContext) { [weak self] progress in
                withAnimation(.snappy) { self?.syncProgress = progress }
            }
            var finished = syncProgress ?? SyncProgress()
            finished.phase = .done
            finished.newItems = count
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { syncProgress = finished }
            hideSyncProgress(after: 4)
            syncMessage = "Sincronización completada · \(count) nuevos"
            if count > 0 {
                NSApplication.shared.dockTile.badgeLabel = "\(count)"
                await notify("Se encontró feedback nuevo (\(count) elementos).")
            }
        } catch ASCError.sessionExpired {
            let wasExpired = connection.sessionState == .expired
            connection.sessionState = .expired
            try? modelContext.save()
            errorMessage = ASCError.sessionExpired.localizedDescription
            syncMessage = "Sesión expirada"
            showSyncFailure(ASCError.sessionExpired.localizedDescription, sessionExpired: true)
            if !wasExpired {
                await notify("Tu sesión de App Store Connect expiró. Vuelve a iniciar sesión para seguir sincronizando.")
            }
        } catch {
            errorMessage = error.localizedDescription
            syncMessage = "Falló la sincronización"
            showSyncFailure(error.localizedDescription, sessionExpired: false)
        }
    }

    func dismissSyncProgress() {
        hideProgressTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { syncProgress = nil }
    }

    private func showSyncFailure(_ message: String, sessionExpired: Bool) {
        var failed = syncProgress ?? SyncProgress()
        failed.fail(message, sessionExpired: sessionExpired)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { syncProgress = failed }
        hideSyncProgress(after: 12)
    }

    private func hideSyncProgress(after seconds: Double) {
        hideProgressTask?.cancel()
        hideProgressTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismissSyncProgress()
        }
    }

    /// Abre el login de Apple para una conexión con sesión expirada y sincroniza al terminar.
    func signInAgain(connection: Connection) {
        AppleLoginWindow.present(connectionId: connection.id, autoClose: true) { [weak self] info in
            guard let self else { return }
            connection.apply(info)
            try? self.modelContext?.save()
            self.errorMessage = nil
            Task { await self.sync(connection: connection) }
        }
    }

    private func notify(_ body: String) async {
        let content = UNMutableNotificationContent()
        content.title = "CuyAppleReport"
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}
