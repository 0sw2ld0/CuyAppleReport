import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Connection.createdAt) private var connections: [Connection]
    @Query(sort: \MonitoredApp.name) private var apps: [MonitoredApp]
    @Query(sort: \Feedback.createdDate, order: .reverse) private var feedback: [Feedback]
    @State private var exportSheet = false
    @State private var fileExporter = false
    @State private var exportDocument = ExportFile(data: Data(), contentType: .commaSeparatedText)
    @State private var exportType: UTType = .commaSeparatedText
    @State private var exportName = "CuyAppleReport"
    @State private var anonymizeEmails = false
    @State private var exportError: String?

    private var activeConnection: Connection? { connections.first }
    private var filteredFeedback: [Feedback] {
        feedback.filter { item in
            (appState.selectedAppId == nil || item.app?.appleId == appState.selectedAppId) &&
            (appState.searchQuery.isEmpty || [item.comment, item.testerEmail, item.deviceModel, item.deviceModel.map { DeviceNames.marketingName($0) }, item.appVersion, item.app?.name]
                .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(appState.searchQuery) })
        }
    }
    private var currentItems: [Feedback] {
        switch appState.page {
        case .dashboard: filteredFeedback
        case .comments: filteredFeedback.filter { $0.kind == "Comentario" }
        case .crashes: filteredFeedback.filter { $0.kind == "Error" }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            content
                .navigationSplitViewColumnWidth(min: 500, ideal: 1000, max: 1500)
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: inspectorPresented) {
            FeedbackInspector(feedback: feedback.first { $0.appleId == appState.selectedFeedbackId })
                .frame(minWidth: 280, idealWidth: 320)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if appState.isSyncing, let progress = appState.syncProgress {
                    Text("Sincronizando · \(Int((progress.fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        .contentTransition(.numericText(value: progress.fraction))
                } else if let syncMessage = appState.syncMessage {
                    Text(syncMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button {
                    guard let connection = activeConnection else { return }
                    Task { await appState.sync(connection: connection) }
                } label: {
                    if appState.isSyncing { SyncSpinner(size: 16) }
                    else { Label("Sincronizar", systemImage: "arrow.clockwise") }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(activeConnection == nil || appState.isSyncing)
                Button { exportSheet = true } label: { Label("Exportar", systemImage: "square.and.arrow.up") }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(currentItems.isEmpty)
                SettingsLink { Label("Ajustes", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $exportSheet) {
            ExportSheet(items: currentItems, initialVersions: appState.selectedVersions) { format, anonymize, versions in
                makeExport(format: format, anonymize: anonymize, versions: versions)
            }
            .frame(width: 440)
        }
        .fileExporter(isPresented: $fileExporter, document: exportDocument, contentType: exportType,
                      defaultFilename: exportName) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("No se pudo exportar", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
        .task {
            appState.modelContext = modelContext
        }
    }

    private var sidebar: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image("CuyAppleReportMark")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CuyAppleReport")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        Text("TESTFLIGHT")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            Section("Apps") {
                sidebarButton("Todas las apps", symbol: "square.grid.2x2", page: .dashboard, appId: nil)
                ForEach(apps.filter(\.isMonitored)) { app in
                    Button {
                        appState.selectedAppId = app.appleId
                        appState.page = .comments
                        appState.selectedFeedbackId = nil
                    } label: {
                        Label(app.name, systemImage: "app.fill").lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appState.selectedAppId == app.appleId ? Color.accentColor : Color.primary)
                }
            }
            Section("Feedback") {
                sidebarButton("Dashboard", symbol: "chart.bar", page: .dashboard, appId: appState.selectedAppId)
                sidebarButton("Comentarios", symbol: "text.bubble", page: .comments, appId: appState.selectedAppId)
                sidebarButton("Errores", symbol: "exclamationmark.triangle", page: .crashes, appId: appState.selectedAppId)
            }
            if let connection = activeConnection {
                Section("Última sync") {
                    Label(connection.apps.compactMap(\.lastSyncAt).max()?.formatted(.relative(presentation: .named)) ?? "Nunca", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("CuyAppleReport")
    }

    private var content: some View {
        Group {
            if activeConnection == nil {
                ContentUnavailableView {
                    Label("Conecta App Store Connect", systemImage: "key.horizontal")
                } description: {
                    Text("Inicia sesión con tu Apple ID o configura una API key para cargar y revisar el feedback de TestFlight.")
                } actions: {
                    SettingsLink { Text("Configurar conexión") }
                }
            } else {
                VStack(spacing: 0) {
                    if let connection = activeConnection, connection.authMode == .webSession, connection.sessionState == .expired {
                        sessionExpiredBanner(connection)
                    }
                    switch appState.page {
                    case .dashboard: DashboardView(feedback: filteredFeedback)
                    case .comments: FeedbackListView(items: filteredFeedback.filter { $0.kind == "Comentario" })
                    case .crashes: FeedbackListView(items: filteredFeedback.filter { $0.kind == "Error" })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottomTrailing) {
            if let progress = appState.syncProgress {
                SyncProgressCard(
                    progress: progress,
                    onClose: { appState.dismissSyncProgress() },
                    onSignIn: activeConnection.map { connection in
                        { appState.dismissSyncProgress(); appState.signInAgain(connection: connection) }
                    }
                )
                .padding(20)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)),
                    removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing))
                ))
            }
        }
    }

    private func sessionExpiredBanner(_ connection: Connection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tu sesión de App Store Connect expiró").font(.headline)
                Text("La sincronización está en pausa. Los datos ya descargados siguen disponibles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Iniciar sesión") { appState.signInAgain(connection: connection) }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }

    private func sidebarButton(_ title: String, symbol: String, page: AppPage, appId: String?) -> some View {
        Button {
            appState.page = page
            appState.selectedAppId = appId
            appState.selectedFeedbackId = nil
        } label: {
            Label(title, systemImage: symbol)
                .foregroundStyle(appState.page == page && appState.selectedAppId == appId ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { appState.selectedFeedbackId != nil },
            set: { isPresented in
                if !isPresented { appState.selectedFeedbackId = nil }
            }
        )
    }

    private func makeExport(format: ExportFormat, anonymize: Bool, versions: Set<String>) {
        do {
            let items = currentItems.filter { versions.contains($0.versionKey) }
            let data = try ExportService.data(for: format, feedback: items, anonymizeEmails: anonymize)
            let type: UTType = switch format {
            case .csv: .commaSeparatedText
            case .xlsx: .xlsx
            case .pdf: .pdf
            }
            exportType = type
            exportDocument = ExportFile(data: data, contentType: type)
            let appName = activeConnection?.apps.first(where: { $0.appleId == appState.selectedAppId })?.name ?? "Todas"
            let safeName = appName.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
            let versionSuffix = versions.count == 1 ? "_v" + (versions.first ?? "").replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression) : ""
            exportName = "CuyAppleReport_\(safeName)\(versionSuffix)_\(Date.now.formatted(.iso8601.year().month().day()))"
            fileExporter = true
        } catch { exportError = error.localizedDescription }
    }
}

private struct ExportSheet: View {
    let items: [Feedback]
    let onExport: (ExportFormat, Bool, Set<String>) -> Void
    private let options: [VersionOptions.Option]
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = .csv
    @State private var anonymizeEmails = false
    @State private var versions: Set<String>

    /// Empieza con las versiones del filtro actual (o todas).
    init(items: [Feedback], initialVersions: Set<String>?, onExport: @escaping (ExportFormat, Bool, Set<String>) -> Void) {
        self.items = items
        self.onExport = onExport
        let options = VersionOptions.options(for: items)
        self.options = options
        let all = Set(options.map(\.version))
        _versions = State(initialValue: initialVersions.map { $0.intersection(all) } ?? all)
    }

    private var selectedCount: Int { items.filter { versions.contains($0.versionKey) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Exportar feedback").font(.title2.bold())
            Text(selectedCount == 1 ? "Se exportará 1 elemento." : "Se exportarán \(selectedCount) elementos.")
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.snappy, value: selectedCount)
            Picker("Formato", selection: $format) {
                ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.radioGroup)
            if !options.isEmpty {
                GroupBox("Versiones de la app") {
                    VersionChecklist(options: options, selection: $versions)
                        .padding(6)
                }
            }
            Toggle("Anonimizar emails de testers", isOn: $anonymizeEmails)
            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Button("Exportar…") { dismiss(); onExport(format, anonymizeEmails, versions) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedCount == 0)
            }
        }
        .padding(24)
    }
}

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .pdf, .xlsx] }
    let data: Data
    let contentType: UTType

    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension UTType {
    static let xlsx = UTType(importedAs: "org.openxmlformats.spreadsheetml.sheet")
}
