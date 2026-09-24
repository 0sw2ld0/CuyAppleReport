import SwiftData
import SwiftUI

@main
struct CuyAppleReportApp: App {
    @StateObject private var appState: AppState
    private let modelContainer: ModelContainer

    init() {
        #if DEBUG
        let inMemory = DemoMode.isEnabled
        #else
        let inMemory = false
        #endif
        do {
            modelContainer = try ModelContainer(for: Connection.self, MonitoredApp.self, Feedback.self, SyncRun.self,
                                                configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
        } catch {
            fatalError("No se pudo iniciar la base de datos local: \(error)")
        }
        let state = AppState()
        state.modelContext = modelContainer.mainContext
        #if DEBUG
        if DemoMode.isEnabled { DemoMode.seed(modelContainer.mainContext) }
        #endif
        state.startAutoSync()
        _appState = StateObject(wrappedValue: state)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MainView()
                .environmentObject(appState)
                .modelContainer(modelContainer)
                .frame(minWidth: 980, minHeight: 650)
                .task {
                    appState.requestNotifications()
                    #if DEBUG
                    if DemoMode.isEnabled {
                        try? await Task.sleep(for: .seconds(2))
                        await DemoMode.runFakeSync(appState)
                    }
                    #endif
                }
        }
        .commands { AppCommands(appState: appState) }

        Settings {
            ConnectionSettingsView()
                .environmentObject(appState)
                .modelContainer(modelContainer)
                .frame(width: 720, height: 720)
        }

        MenuBarExtra("CuyAppleReport", systemImage: "ladybug") {
            MenuBarView()
                .environmentObject(appState)
                .modelContainer(modelContainer)
        }
        .menuBarExtraStyle(.window)
    }
}

struct AppCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Sincronizar ahora") {
                Task { await sync() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Link("Ayuda de App Store Connect API", destination: URL(string: "https://developer.apple.com/documentation/appstoreconnectapi")!)
        }
    }

    @MainActor
    private func sync() async {
        guard let connection = try? appState.modelContext?.fetch(FetchDescriptor<Connection>()).first else { return }
        await appState.sync(connection: connection)
    }
}
