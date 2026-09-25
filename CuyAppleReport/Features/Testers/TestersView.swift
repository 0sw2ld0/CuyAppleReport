import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Estado de los testers de TestFlight: invitaciones, versiones instaladas, grupos y uso de 30 días.
struct TestersView: View {
    let apps: [MonitoredApp]
    @EnvironmentObject private var appState: AppState
    @State private var scope: Scope = .external
    @State private var selectedGroup = "Todos"
    @State private var selectedState = "Todos"
    @State private var selectedVersion = "Todos"
    @State private var exportDocument = ExportFile(data: Data(), contentType: .commaSeparatedText)
    @State private var showExporter = false

    enum Scope: String, CaseIterable, Identifiable {
        case external = "Externos"
        case `internal` = "Internos"
        case all = "Todos"
        var id: String { rawValue }
    }

    private static let notInstalled = "Sin instalar"

    private var allTesters: [BetaTesterRecord] { apps.flatMap(\.testers) }
    private var groups: [BetaGroupRecord] {
        apps.flatMap(\.betaGroups).sorted { ($0.isInternal ? 1 : 0, $0.name) < ($1.isInternal ? 1 : 0, $1.name) }
    }

    /// Testers del alcance elegido (base de las cifras y gráficos).
    private var scoped: [BetaTesterRecord] {
        allTesters.filter { tester in
            switch scope {
            case .external: tester.isExternal
            case .internal: tester.isInternal
            case .all: true
            }
        }
    }

    /// Testers visibles en la tabla (alcance + filtros + búsqueda).
    private var filtered: [BetaTesterRecord] {
        let query = appState.searchQuery.trimmingCharacters(in: .whitespaces)
        return scoped.filter { tester in
            (selectedGroup == "Todos" || tester.groupIds.contains(selectedGroup)) &&
            (selectedState == "Todos" || tester.stateRaw == selectedState) &&
            (selectedVersion == "Todos" || (tester.installedLabel ?? Self.notInstalled) == selectedVersion) &&
            (query.isEmpty || [tester.displayName, tester.email, tester.installedDevice.map { DeviceNames.marketingName($0) }]
                .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) })
        }
        .sorted { lhs, rhs in
            (stateOrder(lhs.state), lhs.displayName.lowercased()) < (stateOrder(rhs.state), rhs.displayName.lowercased())
        }
    }

    private var versionOptions: [String] {
        let labels = Set(scoped.map { $0.installedLabel ?? Self.notInstalled })
        return labels.sorted { lhs, rhs in
            if lhs == Self.notInstalled { return false }
            if rhs == Self.notInstalled { return true }
            return lhs.compare(rhs, options: .numeric) == .orderedDescending
        }
    }

    var body: some View {
        Group {
            if allTesters.isEmpty {
                ContentUnavailableView {
                    Label("Sin datos de testers", systemImage: "person.2")
                } description: {
                    Text("Sincroniza (⌘R) para cargar los testers, sus invitaciones y las versiones que tienen instaladas.")
                }
            } else {
                VStack(spacing: 0) {
                    filterBar
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            kpis
                            HStack(alignment: .top, spacing: 14) {
                                versionChart
                                stateChart
                                groupsPanel
                            }
                            .frame(height: 210)
                        }
                        .padding(16)
                    }
                    .frame(maxHeight: 380)
                    Divider()
                    table
                }
            }
        }
        .searchable(text: $appState.searchQuery, prompt: "Buscar tester o dispositivo")
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "CuyAppleReport_Testers_\(Date.now.formatted(.iso8601.year().month().day()))") { _ in }
    }

    // MARK: Filtros

    private var filterBar: some View {
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
                    ForEach(groups, id: \.groupId) { group in
                        Text(group.isInternal ? "\(group.name) (interno)" : group.name).tag(group.groupId)
                    }
                }
                .frame(width: 220)
                Picker("Estado", selection: $selectedState) {
                    Text("Todos los estados").tag("Todos")
                    ForEach(TesterState.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .frame(width: 170)
                Picker("Versión instalada", selection: $selectedVersion) {
                    Text("Todas").tag("Todos")
                    ForEach(versionOptions, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 230)
                Text("\(filtered.count) testers").font(.caption).foregroundStyle(.secondary).fixedSize()
                Button { exportCSV() } label: { Label("Exportar CSV", systemImage: "square.and.arrow.up") }
                    .disabled(filtered.isEmpty)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
    }

    // MARK: Cifras

    private var kpis: some View {
        let invited = scoped.filter { $0.state == .invited }.count
        let accepted = scoped.filter { $0.state?.hasAccepted == true }.count
        let installed = scoped.filter { $0.state == .installed }.count
        let reachable = invited + accepted
        let acceptance = reachable == 0 ? 0 : Int((Double(accepted) / Double(reachable) * 100).rounded())
        let upToDate = scoped.filter(\.isUpToDate).count
        let latest = latestLabel
        let groupCount = groups.filter { scope == .all || $0.isInternal == (scope == .internal) }.count
        return HStack(spacing: 12) {
            TesterKPI(title: "Testers \(scope == .all ? "" : scope.rawValue.lowercased())", value: "\(scoped.count)",
                      detail: groupCount == 1 ? "1 grupo" : "\(groupCount) grupos", color: .blue, symbol: "person.2.fill")
            TesterKPI(title: "Invitados sin aceptar", value: "\(invited)", detail: "pendientes", color: .orange, symbol: "envelope.badge")
            TesterKPI(title: "Aceptaron", value: "\(accepted)", detail: "\(acceptance)% de aceptación", color: .purple, symbol: "hand.thumbsup.fill")
            TesterKPI(title: "Con la app instalada", value: "\(installed)", detail: "de \(scoped.count)", color: .green, symbol: "iphone.gen3")
            TesterKPI(title: "En la última build", value: "\(upToDate)",
                      detail: latest.map { "\($0) · \(installed == 0 ? 0 : Int(Double(upToDate) / Double(installed) * 100))%" } ?? "sin datos",
                      color: .teal, symbol: "checkmark.seal.fill")
        }
    }

    private var latestLabel: String? {
        guard apps.count == 1, let app = apps.first else { return apps.isEmpty ? nil : "última de cada app" }
        switch (app.latestVersion, app.latestBuild) {
        case let (v?, b?): return "v\(v) (\(b))"
        case let (nil, b?): return "Build \(b)"
        default: return nil
        }
    }

    // MARK: Gráficos

    private var versionChart: some View {
        let latestBuilds = Set(apps.compactMap(\.latestBuild))
        let counts = Dictionary(grouping: scoped, by: { $0.installedLabel ?? Self.notInstalled })
            .map { (label: $0.key, count: $0.value.count, isLatest: $0.value.first.map { latestBuilds.contains($0.installedBuild ?? "") } ?? false) }
            .sorted { lhs, rhs in
                if lhs.label == Self.notInstalled { return false }
                if rhs.label == Self.notInstalled { return true }
                return lhs.label.compare(rhs.label, options: .numeric) == .orderedDescending
            }
        return TesterPanel(title: "Versión instalada") {
            Chart(counts, id: \.label) { item in
                BarMark(x: .value("Testers", item.count), y: .value("Versión", item.label))
                    .foregroundStyle(item.label == Self.notInstalled ? Color.gray.opacity(0.5) : (item.isLatest ? Color.green : Color.blue))
                    .annotation(position: .trailing) { Text("\(item.count)").font(.caption2).foregroundStyle(.secondary) }
                    .cornerRadius(3)
            }
            .chartXAxis(.hidden)
        }
    }

    private var stateChart: some View {
        let counts = TesterState.allCases.compactMap { state -> (state: TesterState, count: Int)? in
            let count = scoped.filter { $0.state == state }.count
            return count == 0 ? nil : (state, count)
        }
        return TesterPanel(title: "Estado de las invitaciones") {
            HStack(spacing: 14) {
                Chart(counts, id: \.state) { item in
                    SectorMark(angle: .value("Testers", item.count), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .foregroundStyle(stateColor(item.state))
                }
                .frame(width: 120)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(counts, id: \.state) { item in
                        HStack(spacing: 6) {
                            Circle().fill(stateColor(item.state)).frame(width: 8, height: 8)
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
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups, id: \.groupId) { group in
                        let members = allTesters.filter { $0.groupIds.contains(group.groupId) }.count
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: group.isInternal ? "building.2" : "globe")
                                    .foregroundStyle(group.isInternal ? Color.secondary : Color.blue)
                                Text(group.name).font(.callout.weight(.medium)).lineLimit(1)
                                Spacer()
                                Text("\(members)").font(.callout.weight(.semibold)).monospacedDigit()
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

    private var table: some View {
        Table(filtered.map(TesterRow.init)) {
            TableColumn("Tester") { tester in
                VStack(alignment: .leading, spacing: 1) {
                    Text(tester.displayName).lineLimit(1)
                    Text([tester.email, apps.count > 1 ? tester.app?.name : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.width(min: 170, ideal: 230)
            TableColumn("Grupo") { tester in
                Text(groupNames(tester.groupIds)).lineLimit(1)
            }.width(min: 90, ideal: 130)
            TableColumn("Estado") { tester in
                if let state = tester.state {
                    Text(state.title).font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(stateColor(state).opacity(0.15), in: Capsule())
                        .foregroundStyle(stateColor(state))
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }.width(min: 80, ideal: 95)
            TableColumn("Versión instalada") { tester in
                if let label = tester.installedLabel {
                    HStack(spacing: 4) {
                        Text(label)
                        if tester.isUpToDate {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Tiene la última build")
                        } else if tester.app?.latestBuild != nil {
                            Image(systemName: "arrow.down.circle").foregroundStyle(.orange).help("No tiene la última build")
                        }
                    }
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }.width(min: 110, ideal: 130)
            TableColumn("Modelo") { tester in
                Text(tester.installedDevice.map { DeviceNames.marketingName($0) } ?? "—").lineLimit(1)
            }.width(min: 110, ideal: 140)
            TableColumn("iOS") { tester in Text(tester.installedOsVersion ?? "—") }.width(min: 50, ideal: 60)
            TableColumn("Disp.") { tester in Text("\(tester.numberOfInstalledDevices)").monospacedDigit() }.width(min: 40, ideal: 45)
            TableColumn("Sesiones 30 d") { tester in Text("\(tester.sessions30)").monospacedDigit() }.width(min: 70, ideal: 85)
            TableColumn("Errores 30 d") { tester in
                Text("\(tester.crashes30)").monospacedDigit().foregroundStyle(tester.crashes30 > 0 ? Color.orange : Color.primary)
            }.width(min: 70, ideal: 80)
            TableColumn("Feedback 30 d") { tester in Text("\(tester.feedback30)").monospacedDigit() }.width(min: 70, ideal: 85)
        }
    }

    // MARK: Utilidades

    private func groupNames(_ ids: [String]) -> String {
        let names = groups.filter { ids.contains($0.groupId) }.map(\.name)
        return names.isEmpty ? "—" : names.joined(separator: ", ")
    }

    private func stateOrder(_ state: TesterState?) -> Int {
        switch state {
        case .invited: 0
        case .accepted: 1
        case .installed: 2
        case .notInvited: 3
        case .revoked: 4
        case nil: 5
        }
    }

    private func stateColor(_ state: TesterState) -> Color {
        switch state {
        case .invited: .orange
        case .accepted: .blue
        case .installed: .green
        case .revoked, .notInvited: .gray
        }
    }

    private func exportCSV() {
        let headers = ["tester", "email", "app", "grupos", "externo", "estado", "invitacion", "version_instalada",
                       "build_instalada", "al_dia", "modelo", "dispositivo", "ios", "dispositivos", "sesiones_30d", "errores_30d", "feedback_30d"]
        let rows = filtered.map { tester -> [String] in
            [tester.displayName, tester.email ?? "", tester.app?.name ?? "", groupNames(tester.groupIds),
             tester.isExternal ? "sí" : "no", tester.state?.title ?? "", tester.inviteType == "PUBLIC_LINK" ? "Enlace público" : "Email",
             tester.installedVersion ?? "", tester.installedBuild ?? "", tester.isUpToDate ? "sí" : "no",
             tester.installedDevice.map { DeviceNames.marketingName($0) } ?? "", tester.installedDevice ?? "",
             tester.installedOsVersion ?? "", "\(tester.numberOfInstalledDevices)",
             "\(tester.sessions30)", "\(tester.crashes30)", "\(tester.feedback30)"]
        }
        let body = ([headers] + rows)
            .map { $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }
            .joined(separator: "\r\n")
        exportDocument = ExportFile(data: Data([0xEF, 0xBB, 0xBF] + Array(body.utf8)), contentType: .commaSeparatedText)
        showExporter = true
    }
}

/// Fila de la tabla identificada por un ID estable (ver `FeedbackRow`).
@dynamicMemberLookup
private struct TesterRow: Identifiable {
    let tester: BetaTesterRecord
    var id: String { tester.recordId }

    subscript<Value>(dynamicMember keyPath: KeyPath<BetaTesterRecord, Value>) -> Value {
        tester[keyPath: keyPath]
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
