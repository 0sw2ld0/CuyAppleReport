import SwiftData
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Connection.createdAt) private var connections: [Connection]
    @Query private var feedback: [Feedback]

    private var newFeedback: [Feedback] { feedback.filter { $0.status == FeedbackStatus.new.rawValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("CuyAppleReport", systemImage: "ladybug").font(.headline)
                Spacer()
                if !newFeedback.isEmpty { Text("\(newFeedback.count)").font(.caption.bold()).padding(5).background(.red, in: Circle()).foregroundStyle(.white) }
            }
            if let connection = connections.first, connection.authMode == .webSession, connection.sessionState == .expired {
                Button {
                    appState.signInAgain(connection: connection)
                } label: {
                    Label("Sesión expirada · Iniciar sesión…", systemImage: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            }
            if connections.first?.apps.filter(\.isMonitored).isEmpty ?? true {
                Text("Configura una conexión en Ajustes.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(connections.first?.apps.filter(\.isMonitored) ?? []) { app in
                    let new = app.feedbacks.filter { $0.status == FeedbackStatus.new.rawValue }
                    HStack {
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Text("\(new.filter { $0.kind == "Comentario" }.count) comentarios · \(new.filter { $0.kind == "Error" }.count) errores")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if appState.isSyncing, let progress = appState.syncProgress {
                HStack(spacing: 10) {
                    SyncSpinner(size: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(progress.phase.title)… \(Int((progress.fraction * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                        GlowingProgressBar(fraction: progress.fraction, colors: [.cyan, .blue, .purple, .pink])
                    }
                }
            }
            Divider()
            Button("Sincronizar ahora") {
                guard let connection = connections.first else { return }
                Task { await appState.sync(connection: connection) }
            }
            .disabled(connections.first == nil || appState.isSyncing)
            Button("Abrir CuyAppleReport") { openWindow(id: "main") }
            SettingsLink { Text("Ajustes…") }
            Button("Salir") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(16).frame(width: 360)
    }
}
