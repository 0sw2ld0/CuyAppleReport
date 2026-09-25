import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Tester ya preparado para mostrar: todo precalculado, sin tocar SwiftData al filtrar ni al dibujar.
/// Con miles de testers, recorrer los modelos en cada redibujado bloqueaba la app.
struct TesterItem: Identifiable, Hashable {
    let id: String
    let displayName: String
    let email: String?
    let appName: String
    let groupIds: [String]
    let groupLabel: String
    let state: TesterState?
    let inviteType: String?
    /// Clave del filtro de versión: "v1.0 (64)" o "Sin instalar".
    let versionKey: String
    let installedVersion: String?
    let installedBuild: String?
    let appHasLatestBuild: Bool
    let isUpToDate: Bool
    let deviceCode: String?
    let deviceName: String?
    let osVersion: String?
    let devices: Int
    let sessions: Int
    let crashes: Int
    let feedback: Int
    let isExternal: Bool
    let isInternal: Bool
    let searchText: String
    let sortRank: Int

    var isInstalled: Bool { versionKey != TesterItem.notInstalled }
    static let notInstalled = "Sin instalar"
}

struct TesterGroupItem: Identifiable, Hashable {
    let id: String
    let name: String
    let isInternal: Bool
    let publicLinkEnabled: Bool
    let publicLinkLimit: Int?
    let feedbackEnabled: Bool
    let members: Int
}

/// Estado de los testers de TestFlight: invitaciones, versiones instaladas, grupos y uso de 30 días.
struct TestersView: View {
    let apps: [MonitoredApp]
    @EnvironmentObject private var appState: AppState
    @State private var items: [TesterItem] = []
    @State private var groups: [TesterGroupItem] = []
    @State private var latestLabel: String?
    @State private var loaded = false
    @State private var scope: Scope = .external
    @State private var selectedGroup = "Todos"
    @State private var selectedState = "Todos"
    /// Versiones instaladas elegidas (`nil` = todas).
    @State private var selectedVersions: Set<String>?
    @State private var exportDocument = ExportFile(data: Data(), contentType: .commaSeparatedText)
    @State private var showExporter = false

    enum Scope: String, CaseIterable, Identifiable {
        case external = "Externos"
        case `internal` = "Internos"
        case all = "Todos"
        var id: String { rawValue }
    }

    /// Identidad de la tabla: cambia con los filtros o los datos, para reconstruirla en vez de compararla.
    private var tableIdentity: String {
        [snapshotKey, scope.rawValue, selectedGroup, selectedState,
         selectedVersions.map { $0.sorted().joined(separator: ",") } ?? "*", appState.searchQuery].joined(separator: "§")
    }

    /// Cambia solo cuando se sincronizan testers o cambian las apps visibles.
    private var snapshotKey: String {
        apps.map { "\($0.appleId):\($0.testersSyncedAt?.timeIntervalSince1970 ?? 0)" }.joined(separator: "|")
    }

    var body: some View {
        // Un único filtrado por redibujado; las cifras, gráficos y tabla reciben el resultado.
        let scoped = items.filter(inScope)
        let visible = scoped.filter(matchesFilters)
        Group {
            if !loaded {
                ProgressView("Preparando testers…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("Sin datos de testers", systemImage: "person.2")
                } description: {
                    Text("Sincroniza (⌘R) para cargar los testers, sus invitaciones y las versiones que tienen instaladas.")
                }
            } else {
                VStack(spacing: 0) {
                    filterBar(scoped: scoped, visible: visible)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            kpis(scoped)
                            HStack(alignment: .top, spacing: 14) {
                                versionChart(scoped)
                                stateChart(scoped)
                                groupsPanel
                            }
                            .frame(height: 210)
                        }
                        .padding(16)
                    }
                    .frame(maxHeight: 380)
                    Divider()
                    // Con muchos testers, que SwiftUI compare y anime las filas al cambiar un filtro
                    // bloqueaba la app varios segundos: se reconstruye la tabla en su lugar.
                    table(visible)
                        .id(tableIdentity)
                }
            }
        }
        .task(id: snapshotKey) { rebuildSnapshot() }
        #if DEBUG
        .task { if ProcessInfo.processInfo.arguments.contains("--bench-testers") { await benchmark() } }
        #endif
        .searchable(text: $appState.searchQuery, prompt: "Buscar tester o dispositivo")
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "CuyAppleReport_Testers_\(Date.now.formatted(.iso8601.year().month().day()))") { _ in }
    }

    // MARK: Datos

    /// Convierte los modelos en valores una sola vez por sincronización.
    private func rebuildSnapshot() {
        var groupItems: [TesterGroupItem] = []
        var testerItems: [TesterItem] = []
        for app in apps {
            let appGroups = app.betaGroups
            let names = Dictionary(appGroups.map { ($0.groupId, $0.name) }, uniquingKeysWith: { first, _ in first })
            var members: [String: Int] = [:]
            let latestBuild = app.latestBuild
            for tester in app.testers {
                let groupIds = tester.groupIds
                for id in groupIds { members[id, default: 0] += 1 }
                let state = tester.state
                let installedLabel = tester.installedLabel
                let deviceName = tester.installedDevice.map { DeviceNames.marketingName($0) }
                let name = tester.displayName
                let groupNames = groupIds.compactMap { names[$0] }
                testerItems.append(TesterItem(
                    id: tester.recordId, displayName: name, email: tester.email, appName: app.name,
                    groupIds: groupIds, groupLabel: groupNames.isEmpty ? "—" : groupNames.joined(separator: ", "),
                    state: state, inviteType: tester.inviteType,
                    versionKey: installedLabel ?? TesterItem.notInstalled,
                    installedVersion: tester.installedVersion, installedBuild: tester.installedBuild,
                    appHasLatestBuild: latestBuild != nil,
                    isUpToDate: latestBuild != nil && tester.installedBuild == latestBuild,
                    deviceCode: tester.installedDevice, deviceName: deviceName, osVersion: tester.installedOsVersion,
                    devices: tester.numberOfInstalledDevices,
                    sessions: tester.sessions30, crashes: tester.crashes30, feedback: tester.feedback30,
                    isExternal: tester.isExternal, isInternal: tester.isInternal,
                    searchText: [name, tester.email, deviceName, tester.installedDevice].compactMap { $0 }.joined(separator: " ").lowercased(),
                    sortRank: Self.stateOrder(state)))
            }
            groupItems += appGroups.map {
                TesterGroupItem(id: $0.groupId, name: $0.name, isInternal: $0.isInternal, publicLinkEnabled: $0.publicLinkEnabled,
                                publicLinkLimit: $0.publicLinkLimit, feedbackEnabled: $0.feedbackEnabled, members: members[$0.groupId] ?? 0)
            }
        }
        items = testerItems.sorted { ($0.sortRank, $0.displayName.lowercased()) < ($1.sortRank, $1.displayName.lowercased()) }
        groups = groupItems.sorted { ($0.isInternal ? 1 : 0, $0.name) < ($1.isInternal ? 1 : 0, $1.name) }
        if apps.count == 1, let app = apps.first {
            latestLabel = switch (app.latestVersion, app.latestBuild) {
            case let (v?, b?): "v\(v) (\(b))"
            case let (nil, b?): "Build \(b)"
            default: nil
            }
        } else {
            latestLabel = apps.isEmpty ? nil : "última de cada app"
        }
        // Filtros que ya no existen tras sincronizar.
        if let versions = selectedVersions { selectedVersions = versions.intersection(Set(items.map(\.versionKey))) }
        if selectedGroup != "Todos", !groups.contains(where: { $0.id == selectedGroup }) { selectedGroup = "Todos" }
        loaded = true
    }

    private func inScope(_ tester: TesterItem) -> Bool {
        switch scope {
        case .external: tester.isExternal
        case .internal: tester.isInternal
        case .all: true
        }
    }

    private func matchesFilters(_ tester: TesterItem) -> Bool {
        let query = appState.searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return (selectedGroup == "Todos" || tester.groupIds.contains(selectedGroup)) &&
            (selectedState == "Todos" || tester.state?.rawValue == selectedState) &&
            (selectedVersions?.contains(tester.versionKey) ?? true) &&
            (query.isEmpty || tester.searchText.contains(query))
    }

    private func versionOptions(_ scoped: [TesterItem]) -> [VersionOptions.Option] {
        var counts: [String: Int] = [:]
        for tester in scoped { counts[tester.versionKey, default: 0] += 1 }
        return counts.map { VersionOptions.Option(version: $0.key, count: $0.value, title: $0.key) }
            .sorted { lhs, rhs in
                if lhs.version == TesterItem.notInstalled { return false }
                if rhs.version == TesterItem.notInstalled { return true }
                return lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending
            }
    }

    // MARK: Filtros

    private func filterBar(scoped: [TesterItem], visible: [TesterItem]) -> some View {
        ScrollView(.horizontal) {
            HStack {
                Text("Alcance").fixedSize()
                Picker("Alcance", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                Picker("Grupo", selection: $selectedGroup) {
                    Text("Todos los grupos").tag("Todos")
                    ForEach(groups) { group in
                        Text(group.isInternal ? "\(group.name) (interno)" : group.name).tag(group.id)
                    }
                }
                .frame(width: 220)
                Picker("Estado", selection: $selectedState) {
                    Text("Todos los estados").tag("Todos")
                    ForEach(TesterState.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .frame(width: 170)
                Text("Versión instalada").fixedSize()
                VersionFilterButton(options: versionOptions(scoped), selection: $selectedVersions)
                Text("\(visible.count.formatted()) testers").font(.caption).foregroundStyle(.secondary).fixedSize()
                Button { exportCSV(visible) } label: { Label("Exportar CSV", systemImage: "square.and.arrow.up") }
                    .disabled(visible.isEmpty)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
    }

    // MARK: Cifras

    private func kpis(_ scoped: [TesterItem]) -> some View {
        var invited = 0, accepted = 0, installed = 0, upToDate = 0
        for tester in scoped {
            if tester.state == .invited { invited += 1 }
            if tester.state?.hasAccepted == true { accepted += 1 }
            if tester.state == .installed { installed += 1 }
            if tester.isUpToDate { upToDate += 1 }
        }
        let reachable = invited + accepted
        let acceptance = reachable == 0 ? 0 : Int((Double(accepted) / Double(reachable) * 100).rounded())
        let groupCount = groups.filter { scope == .all || $0.isInternal == (scope == .internal) }.count
        let upToDatePercent = installed == 0 ? 0 : Int(Double(upToDate) / Double(installed) * 100)
        return HStack(spacing: 12) {
            TesterKPI(title: "Testers \(scope == .all ? "" : scope.rawValue.lowercased())", value: scoped.count.formatted(),
                      detail: groupCount == 1 ? "1 grupo" : "\(groupCount) grupos", color: .blue, symbol: "person.2.fill")
            TesterKPI(title: "Invitados sin aceptar", value: invited.formatted(), detail: "pendientes", color: .orange, symbol: "envelope.badge")
            TesterKPI(title: "Aceptaron", value: accepted.formatted(), detail: "\(acceptance)% de aceptación", color: .purple, symbol: "hand.thumbsup.fill")
            TesterKPI(title: "Con la app instalada", value: installed.formatted(), detail: "de \(scoped.count.formatted())", color: .green, symbol: "iphone.gen3")
            TesterKPI(title: "En la última build", value: upToDate.formatted(),
                      detail: latestLabel.map { "\($0) · \(upToDatePercent)%" } ?? "sin datos",
                      color: .teal, symbol: "checkmark.seal.fill")
        }
    }

    // MARK: Gráficos

    private struct VersionBar: Identifiable {
        let label: String
        let count: Int
        let isLatest: Bool
        var id: String { label }
    }

    private func versionChart(_ scoped: [TesterItem]) -> some View {
        var counts: [String: (count: Int, latest: Bool)] = [:]
        var notInstalled = 0
        for tester in scoped {
            guard tester.isInstalled else { notInstalled += 1; continue }
            let current = counts[tester.versionKey] ?? (0, false)
            counts[tester.versionKey] = (current.count + 1, current.latest || tester.isUpToDate)
        }
        var bars = counts.map { VersionBar(label: $0.key, count: $0.value.count, isLatest: $0.value.latest) }
            .sorted { $0.label.compare($1.label, options: .numeric) == .orderedDescending }
        // Las 5 versiones más recientes y el resto agrupado, para que el gráfico se lea bien.
        if bars.count > 6 {
            let rest = bars.dropFirst(5).reduce(0) { $0 + $1.count }
            bars = Array(bars.prefix(5)) + [VersionBar(label: "Otras", count: rest, isLatest: false)]
        }
        return TesterPanel(title: "Versión instalada") {
            VStack(alignment: .leading, spacing: 6) {
                if bars.isEmpty {
                    Text("Nadie tiene la app instalada todavía.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Chart(bars) { bar in
                        BarMark(x: .value("Testers", bar.count), y: .value("Versión", bar.label))
                            .foregroundStyle(bar.label == "Otras" ? Color.gray.opacity(0.5) : (bar.isLatest ? Color.green : Color.blue))
                            .annotation(position: .trailing) {
                                Text(bar.count.formatted()).font(.caption2).foregroundStyle(.secondary)
                            }
                            .cornerRadius(3)
                    }
                    .chartXAxis(.hidden)
                }
                if notInstalled > 0 {
                    Text("Sin instalar: \(notInstalled.formatted())").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stateChart(_ scoped: [TesterItem]) -> some View {
        var byState: [TesterState: Int] = [:]
        for tester in scoped { if let state = tester.state { byState[state, default: 0] += 1 } }
        let counts = TesterState.allCases.compactMap { state in byState[state].map { (state: state, count: $0) } }
        return TesterPanel(title: "Estado de las invitaciones") {
            HStack(spacing: 14) {
                Chart(counts, id: \.state) { item in
                    SectorMark(angle: .value("Testers", item.count), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .foregroundStyle(Self.stateColor(item.state))
                }
                .frame(width: 120)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(counts, id: \.state) { item in
                        HStack(spacing: 6) {
                            Circle().fill(Self.stateColor(item.state)).frame(width: 8, height: 8)
                            Text(item.state.title).font(.caption)
                            Spacer()
                            Text("\(item.count)").font(.caption.weight(.semibold)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private var groupsPanel: some View {
        TesterPanel(title: "Grupos") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: group.isInternal ? "building.2" : "globe")
                                    .foregroundStyle(group.isInternal ? Color.secondary : Color.blue)
                                Text(group.name).font(.callout.weight(.medium)).lineLimit(1)
                                Spacer()
                                Text(group.members.formatted()).font(.callout.weight(.semibold)).monospacedDigit()
                            }
                            HStack(spacing: 6) {
                                Text(group.isInternal ? "Interno" : "Externo")
                                if group.publicLinkEnabled {
                                    Text("· Enlace público\(group.publicLinkLimit.map { " (límite \($0))" } ?? "")")
                                }
                                if !group.feedbackEnabled { Text("· Feedback desactivado") }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Tabla

    private func table(_ visible: [TesterItem]) -> some View {
        let showApp = apps.count > 1
        return Table(visible) {
            TableColumn("Tester") { tester in
                VStack(alignment: .leading, spacing: 1) {
                    Text(tester.displayName).lineLimit(1)
                    Text([tester.email, showApp ? tester.appName : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.width(min: 170, ideal: 230)
            TableColumn("Grupo") { tester in Text(tester.groupLabel).lineLimit(1) }.width(min: 90, ideal: 130)
            TableColumn("Estado") { tester in
                if let state = tester.state {
                    Text(state.title).font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Self.stateColor(state).opacity(0.15), in: Capsule())
                        .foregroundStyle(Self.stateColor(state))
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }.width(min: 80, ideal: 95)
            TableColumn("Versión instalada") { tester in
                if tester.isInstalled {
                    HStack(spacing: 4) {
                        Text(tester.versionKey)
                        if tester.isUpToDate {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Tiene la última build")
                        } else if tester.appHasLatestBuild {
                            Image(systemName: "arrow.down.circle").foregroundStyle(.orange).help("No tiene la última build")
                        }
                    }
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }.width(min: 110, ideal: 130)
            TableColumn("Modelo") { tester in Text(tester.deviceName ?? "—").lineLimit(1) }.width(min: 110, ideal: 140)
            TableColumn("iOS") { tester in Text(tester.osVersion ?? "—") }.width(min: 50, ideal: 60)
            TableColumn("Disp.") { tester in Text("\(tester.devices)").monospacedDigit() }.width(min: 40, ideal: 45)
            TableColumn("Sesiones 30 d") { tester in Text("\(tester.sessions)").monospacedDigit() }.width(min: 70, ideal: 85)
            TableColumn("Errores 30 d") { tester in
                Text("\(tester.crashes)").monospacedDigit().foregroundStyle(tester.crashes > 0 ? Color.orange : Color.primary)
            }.width(min: 70, ideal: 80)
            TableColumn("Feedback 30 d") { tester in Text("\(tester.feedback)").monospacedDigit() }.width(min: 70, ideal: 85)
        }
    }

    #if DEBUG
    /// Repite "elegir una versión → Todas" y muestra el peor bloqueo del hilo principal en cada paso.
    private func benchmark() async {
        while !loaded { try? await Task.sleep(for: .milliseconds(100)) }
        DemoMode.startHangMonitor()
        try? await Task.sleep(for: .seconds(1.5))
        print("BENCH testers=\(items.count) arranque_peor_ms=\(DemoMode.hangMonitor?.take() ?? -1)")
        let versions = Array(Set(items.map(\.versionKey))).sorted()
        for version in versions.prefix(5) {
            selectedVersions = [version]
            try? await Task.sleep(for: .seconds(1))
            let one = DemoMode.hangMonitor?.take() ?? -1
            selectedVersions = nil
            try? await Task.sleep(for: .seconds(1.2))
            let all = DemoMode.hangMonitor?.take() ?? -1
            print("BENCH versión \(version): peor_ms una=\(one) todas=\(all)")
        }
        print("BENCH fin")
        exit(0)
    }
    #endif

    // MARK: Utilidades

    private static func stateOrder(_ state: TesterState?) -> Int {
        switch state {
        case .invited: 0
        case .accepted: 1
        case .installed: 2
        case .notInvited: 3
        case .revoked: 4
        case nil: 5
        }
    }

    private static func stateColor(_ state: TesterState) -> Color {
        switch state {
        case .invited: .orange
        case .accepted: .blue
        case .installed: .green
        case .revoked, .notInvited: .gray
        }
    }

    private func exportCSV(_ visible: [TesterItem]) {
        let headers = ["tester", "email", "app", "grupos", "externo", "estado", "invitacion", "version_instalada",
                       "build_instalada", "al_dia", "modelo", "dispositivo", "ios", "dispositivos", "sesiones_30d", "errores_30d", "feedback_30d"]
        let rows = visible.map { tester -> [String] in
            [tester.displayName, tester.email ?? "", tester.appName, tester.groupLabel,
             tester.isExternal ? "sí" : "no", tester.state?.title ?? "", tester.inviteType == "PUBLIC_LINK" ? "Enlace público" : "Email",
             tester.installedVersion ?? "", tester.installedBuild ?? "", tester.isUpToDate ? "sí" : "no",
             tester.deviceName ?? "", tester.deviceCode ?? "", tester.osVersion ?? "", "\(tester.devices)",
             "\(tester.sessions)", "\(tester.crashes)", "\(tester.feedback)"]
        }
        let body = ([headers] + rows)
            .map { $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }
            .joined(separator: "\r\n")
        exportDocument = ExportFile(data: Data([0xEF, 0xBB, 0xBF] + Array(body.utf8)), contentType: .commaSeparatedText)
        showExporter = true
    }
}

private struct TesterKPI: View {
    let title: String
    let value: String
    let detail: String
    let color: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}

private struct TesterPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}
