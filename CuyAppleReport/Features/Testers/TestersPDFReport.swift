import Charts
import SwiftUI

// MARK: - Opciones

enum TesterListMode: String, CaseIterable, Identifiable {
    case all = "Todos los testers"
    case reporters = "Solo los que enviaron comentarios o errores"
    case none = "No incluir la lista"
    var id: String { rawValue }
}

struct TestersPDFOptions {
    var versions: Set<String>
    var includeEmails: Bool
    var listMode: TesterListMode
}

/// Hoja para elegir qué entra en el informe PDF de testers.
struct TestersPDFSheet: View {
    let items: [TesterItem]
    let options: [VersionOptions.Option]
    let filtersText: String
    let onExport: (TestersPDFOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var versions: Set<String>
    @State private var includeEmails = false
    @State private var listMode: TesterListMode = .all

    /// Empieza con las versiones del filtro actual (o todas).
    init(items: [TesterItem], options: [VersionOptions.Option], initialVersions: Set<String>?,
         filtersText: String, onExport: @escaping (TestersPDFOptions) -> Void) {
        self.items = items
        self.options = options
        self.filtersText = filtersText
        self.onExport = onExport
        let all = Set(options.map(\.version))
        _versions = State(initialValue: initialVersions.map { $0.intersection(all) } ?? all)
    }

    private var selectedCount: Int { items.filter { versions.contains($0.versionKey) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Informe PDF de testers").font(.title2.bold())
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedCount == 1 ? "Se incluirá 1 tester." : "Se incluirán \(selectedCount.formatted()) testers.")
                    .contentTransition(.numericText())
                    .animation(.snappy, value: selectedCount)
                Text(filtersText).font(.caption).foregroundStyle(.secondary)
            }
            GroupBox("Versión instalada") {
                VersionChecklist(options: options, selection: $versions).padding(6)
            }
            Picker("Lista de testers", selection: $listMode) {
                ForEach(TesterListMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Toggle("Incluir los correos de los testers", isOn: $includeEmails)
            Text(includeEmails
                 ? "El informe mostrará el correo de cada tester."
                 : "El informe no mostrará correos: solo el nombre, o “Tester sin nombre” si TestFlight no lo tiene.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Button("Exportar PDF…") {
                    dismiss()
                    onExport(TestersPDFOptions(versions: versions, includeEmails: includeEmails, listMode: listMode))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCount == 0)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - Render

@MainActor
enum TestersPDFRenderer {
    static func render(testers: [TesterItem], installs: [InstallItem], appNames: String, filtersText: String,
                       latestLabel: String?, options: TestersPDFOptions) throws -> Data {
        let report = TestersReport(testers: testers, installs: installs, appNames: appNames, filtersText: filtersText,
                                   latestLabel: latestLabel, options: options)
        let pages = report.pages
        return try PDFReportRenderer.renderPages(title: "Informe de testers TestFlight", count: pages.count) { index in
            TestersPageView(page: pages[index], report: report, number: index + 1, total: pages.count)
        }
    }
}

// MARK: - Datos

struct VersionReportBar: Identifiable {
    let version: String
    let kind: String
    let count: Int
    var id: String { "\(version)-\(kind)" }
}

struct ReporterRow: Identifiable {
    let id: String
    let name: String
    let comments: Int
    let crashes: Int
}

/// Testers con la misma versión instalada.
struct VersionGroup: Identifiable {
    let version: String
    let testers: Int
    let upToDate: Bool
    let models: [Ranked]
    let osVersions: [Ranked]
    let comments: Int
    let crashes: Int
    var id: String { version }
}

struct TesterRow: Identifiable {
    let id: String
    let name: String
    let email: String?
    let state: String
    let version: String
    let build: String?
    let installedDate: Date?
    let model: String
    let os: String
    let sessions: Int
    let comments: Int
    let crashes: Int
}

enum TestersPage {
    case summary
    case reports
    case evolution
    case daily
    case versions([VersionGroup], isFirst: Bool)
    case list([TesterRow], isFirst: Bool)
}

struct TestersReport {
    let appNames: String
    let filtersText: String
    let versionsText: String
    let latestLabel: String?
    let includeEmails: Bool
    let listMode: TesterListMode
    let timeline: InstallTimeline
    let adoption: [AdoptionRow]
    let daily: [DailyInstallRow]

    let total: Int
    let installed: Int
    let accepted: Int
    let invited: Int
    let upToDate: Int
    let notInstalled: Int
    let versionBars: [Ranked]
    let latestVersionKeys: Set<String>
    let models: [Ranked]
    let osVersions: [Ranked]
    let states: [Ranked]

    let withComments: Int
    let withCrashes: Int
    let withBoth: Int
    let totalComments: Int
    let totalCrashes: Int
    let crashes30: Int
    let sessions30: Int
    let reportsByVersion: [VersionReportBar]
    let crashesByModel: [Ranked]
    let topReporters: [ReporterRow]
    let versionGroups: [VersionGroup]
    let rows: [TesterRow]

    var acceptance: Int {
        let reachable = invited + accepted
        return reachable == 0 ? 0 : Int((Double(accepted) / Double(reachable) * 100).rounded())
    }
    var anyReports: Bool { totalComments + totalCrashes > 0 }

    init(testers: [TesterItem], installs: [InstallItem], appNames: String, filtersText: String,
         latestLabel: String?, options: TestersPDFOptions) {
        timeline = InstallTimeline(installs: installs, period: .all, maxSeries: 6)
        adoption = AdoptionRow.rows(installs, limit: 10)
        daily = DailyInstallRow.rows(installs)
        self.appNames = appNames
        self.filtersText = filtersText
        self.latestLabel = latestLabel
        includeEmails = options.includeEmails
        listMode = options.listMode
        let sortedVersions = options.versions.sorted(by: Self.newestFirst)
        versionsText = sortedVersions.count > 4
            ? "\(sortedVersions.count) versiones instaladas"
            : sortedVersions.joined(separator: ", ")

        var installed = 0, accepted = 0, invited = 0, upToDate = 0
        var versionCounts: [String: Int] = [:]
        var latestKeys: Set<String> = []
        var modelValues: [String] = []
        var osValues: [String] = []
        var stateCounts: [TesterState: Int] = [:]
        var withComments = 0, withCrashes = 0, withBoth = 0, totalComments = 0, totalCrashes = 0
        var crashes30 = 0, sessions30 = 0
        var reportsByVersion: [String: (comments: Int, crashes: Int)] = [:]
        var crashModels: [String: Int] = [:]
        var reporters: [ReporterRow] = []
        var byVersion: [String: [TesterItem]] = [:]

        for tester in testers {
            if let state = tester.state { stateCounts[state, default: 0] += 1 }
            if tester.state == .invited { invited += 1 }
            if tester.state?.hasAccepted == true { accepted += 1 }
            if tester.isInstalled {
                installed += 1
                versionCounts[tester.versionKey, default: 0] += 1
                modelValues.append(tester.deviceName ?? "Sin dato")
                osValues.append(tester.osVersion.map { "iOS \($0)" } ?? "Sin dato")
            }
            if tester.isUpToDate {
                upToDate += 1
                latestKeys.insert(tester.versionKey)
            }
            byVersion[tester.versionKey, default: []].append(tester)
            crashes30 += tester.crashes
            sessions30 += tester.sessions

            let comments = tester.commentReports
            let crashes = tester.crashReports
            totalComments += comments
            totalCrashes += crashes
            if comments > 0 { withComments += 1 }
            if crashes > 0 { withCrashes += 1 }
            if comments > 0, crashes > 0 { withBoth += 1 }
            if comments + crashes > 0 {
                let current = reportsByVersion[tester.versionKey] ?? (0, 0)
                reportsByVersion[tester.versionKey] = (current.comments + comments, current.crashes + crashes)
                reporters.append(ReporterRow(id: tester.id, name: Self.name(tester),
                                             comments: comments, crashes: crashes))
            }
            if crashes > 0 { crashModels[tester.deviceName ?? "Sin dato", default: 0] += crashes }
        }

        total = testers.count
        self.installed = installed
        self.accepted = accepted
        self.invited = invited
        self.upToDate = upToDate
        notInstalled = testers.count - installed
        latestVersionKeys = latestKeys

        // Versiones de la más reciente a la más antigua; a partir de la octava se agrupan en "Otras".
        var bars = versionCounts.map { Ranked(name: $0.key, count: $0.value) }
            .sorted { Self.newestFirst($0.name, $1.name) }
        if bars.count > 8 {
            let rest = bars.dropFirst(7).reduce(0) { $0 + $1.count }
            bars = Array(bars.prefix(7)) + [Ranked(name: "Otras", count: rest)]
        }
        versionBars = bars
        models = Self.rank(modelValues, limit: 6)
        osVersions = Self.rank(osValues, limit: 6)
        states = TesterState.allCases.compactMap { state in stateCounts[state].map { Ranked(name: state.title, count: $0) } }

        self.withComments = withComments
        self.withCrashes = withCrashes
        self.withBoth = withBoth
        self.totalComments = totalComments
        self.totalCrashes = totalCrashes
        self.crashes30 = crashes30
        self.sessions30 = sessions30

        var reportBars: [VersionReportBar] = []
        let reportVersions = reportsByVersion.keys.sorted(by: Self.newestFirst).prefix(8)
        for version in reportVersions {
            guard let counts = reportsByVersion[version] else { continue }
            if counts.comments > 0 { reportBars.append(VersionReportBar(version: version, kind: "Comentarios", count: counts.comments)) }
            if counts.crashes > 0 { reportBars.append(VersionReportBar(version: version, kind: "Errores", count: counts.crashes)) }
        }
        self.reportsByVersion = reportBars
        crashesByModel = Self.rank(counts: crashModels, limit: 6)
        let sortedReporters = reporters.sorted { lhs, rhs in
            let left = lhs.comments + lhs.crashes
            let right = rhs.comments + rhs.crashes
            return left == right ? lhs.name < rhs.name : left > right
        }
        topReporters = Array(sortedReporters.prefix(8))

        var groups: [VersionGroup] = []
        for version in byVersion.keys.sorted(by: Self.newestFirst) {
            let members = byVersion[version] ?? []
            var memberModels: [String] = []
            var memberOS: [String] = []
            var comments = 0
            var crashes = 0
            for member in members {
                comments += member.commentReports
                crashes += member.crashReports
                guard member.isInstalled else { continue }
                memberModels.append(member.deviceName ?? "Sin dato")
                memberOS.append(member.osVersion.map { "iOS \($0)" } ?? "Sin dato")
            }
            groups.append(VersionGroup(
                version: version, testers: members.count, upToDate: latestKeys.contains(version),
                models: Self.rank(memberModels, limit: 3), osVersions: Self.rank(memberOS, limit: 3),
                comments: comments, crashes: crashes))
        }
        versionGroups = groups

        let listed: [TesterItem] = switch options.listMode {
        case .all: testers
        case .reporters: testers.filter { $0.commentReports + $0.crashReports > 0 }
        case .none: []
        }
        rows = listed.map { tester in
            TesterRow(id: tester.id, name: Self.name(tester),
                      email: options.includeEmails ? tester.email : nil,
                      state: tester.state?.title ?? "—",
                      version: tester.isInstalled ? (tester.installedVersion.map { "v\($0)" } ?? "Build") : "—",
                      build: tester.isInstalled ? tester.installedBuild : nil, installedDate: tester.installedDate,
                      model: tester.deviceName ?? "—", os: tester.osVersion ?? "—", sessions: tester.sessions,
                      comments: tester.commentReports, crashes: tester.crashReports)
        }
    }

    var pages: [TestersPage] {
        var pages: [TestersPage] = [.summary, .reports]
        if !timeline.isEmpty { pages += [.evolution, .daily] }
        pages += Self.chunks(versionGroups, first: 4, rest: 5).enumerated().map { .versions($0.element, isFirst: $0.offset == 0) }
        pages += Self.chunks(rows, first: includeEmails ? 25 : 30, rest: includeEmails ? 27 : 32).enumerated().map { .list($0.element, isFirst: $0.offset == 0) }
        return pages
    }

    private static func chunks<T>(_ values: [T], first: Int, rest: Int) -> [[T]] {
        var result: [[T]] = []
        var index = 0
        while index < values.count {
            let size = result.isEmpty ? first : rest
            result.append(Array(values[index..<min(index + size, values.count)]))
            index += size
        }
        return result
    }

    /// Solo el nombre real: TestFlight usa el correo como nombre cuando no tiene otro, y el correo va en su columna.
    private static func name(_ tester: TesterItem) -> String {
        tester.name ?? "Tester sin nombre"
    }

    /// "Sin instalar" siempre al final; el resto de la versión más reciente a la más antigua.
    private static func newestFirst(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == TesterItem.notInstalled { return false }
        if rhs == TesterItem.notInstalled { return true }
        return lhs.compare(rhs, options: .numeric) == .orderedDescending
    }

    private static func rank(_ values: [String], limit: Int) -> [Ranked] {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return rank(counts: counts, limit: limit)
    }

    private static func rank(counts: [String: Int], limit: Int) -> [Ranked] {
        let ranked: [Ranked] = counts.map { Ranked(name: $0.key, count: $0.value) }
        let sorted = ranked.sorted { (lhs: Ranked, rhs: Ranked) -> Bool in
            lhs.count == rhs.count ? lhs.name < rhs.name : lhs.count > rhs.count
        }
        return Array(sorted.prefix(limit))
    }
}

// MARK: - Páginas

private struct TestersPageView: View {
    let page: TestersPage
    let report: TestersReport
    let number: Int
    let total: Int

    var body: some View {
        switch page {
        case .summary:
            PageScaffold(appNames: report.appNames, number: number, total: total,
                         eyebrow: "TESTERS", title: "Estado de los testers") { TestersSummary(report: report) }
        case .reports:
            PageScaffold(appNames: report.appNames, number: number, total: total,
                         eyebrow: "REPORTES", title: "¿Quién envió comentarios o errores?") { TestersReports(report: report) }
        case .evolution:
            PageScaffold(appNames: report.appNames, number: number, total: total,
                         eyebrow: "EVOLUCIÓN", title: "Cómo se instalaron las versiones") { TestersEvolution(report: report) }
        case .daily:
            PageScaffold(appNames: report.appNames, number: number, total: total,
                         eyebrow: "ÚLTIMOS 30 DÍAS", title: "Testers con la app, día a día") { TestersDaily(rows: report.daily) }
        case .versions(let groups, let isFirst):
            PageScaffold(appNames: report.appNames, number: number, total: total,
                         eyebrow: "POR VERSIÓN", title: isFirst ? "Qué iPhone e iOS usa cada versión" : nil) {
                VStack(spacing: 12) {
                    ForEach(groups) { VersionGroupCard(group: $0, total: report.total) }
                    Spacer(minLength: 0)
                }
            }
        case .list(let rows, let isFirst):
            PageScaffold(appNames: report.appNames, number: number, total: total,
                         eyebrow: "DETALLE", title: isFirst ? "Lista de testers" : nil) {
                TesterTable(rows: rows, showEmail: report.includeEmails)
            }
        }
    }
}

private struct TestersSummary: View {
    let report: TestersReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(report.filtersText).font(.system(size: 10, weight: .medium)).foregroundStyle(RP.ink)
                Text("Versiones incluidas: \(report.versionsText) · Generado el \(RP.date(.now, .long, time: .shortened))")
                    .font(.system(size: 9)).foregroundStyle(RP.muted)
            }
            HStack(spacing: 10) {
                KPI(value: report.total, label: "Testers", color: RP.blue)
                KPI(value: report.accepted, label: "Aceptaron · \(report.acceptance)%", color: RP.purple)
                KPI(value: report.installed, label: "Con la app", color: RP.green)
                KPI(value: report.upToDate, label: "En la última build", color: RP.cyan)
            }
            Card(title: "Versión instalada") {
                if report.versionBars.isEmpty {
                    Text("Ninguno de estos testers tiene la app instalada.").font(.system(size: 10)).foregroundStyle(RP.muted)
                } else {
                    Chart(report.versionBars) { bar in
                        BarMark(x: .value("Testers", bar.count), y: .value("Versión", bar.name))
                            .foregroundStyle(barColor(bar.name))
                            .cornerRadius(3)
                            .annotation(position: .trailing) {
                                Text("\(bar.count)").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(RP.ink)
                            }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(RP.ink) } }
                    .frame(height: CGFloat(report.versionBars.count) * 20 + 10)
                }
                if report.notInstalled > 0 {
                    Text("Sin instalar: \(report.notInstalled) · En verde, la última build subida\(report.latestLabel.map { " (\($0))" } ?? "").")
                        .font(.system(size: 8.5)).foregroundStyle(RP.muted)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                Card(title: "Modelos de iPhone") { RankBars(items: report.models, color: RP.blue) }
                Card(title: "Versiones de iOS") { RankBars(items: report.osVersions, color: RP.purple) }
            }
            Card(title: "Estado de las invitaciones") {
                HStack(spacing: 8) {
                    ForEach(report.states) { state in
                        HStack(spacing: 6) {
                            Circle().fill(stateColor(state.name)).frame(width: 7, height: 7)
                            Text(state.name).font(.system(size: 10)).foregroundStyle(RP.ink)
                            Text("\(state.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(RP.ink)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RP.faint, in: Capsule())
                    }
                    Spacer()
                }
            }
        }
    }

    private func barColor(_ version: String) -> Color {
        if version == "Otras" { return RP.muted.opacity(0.5) }
        return report.latestVersionKeys.contains(version) ? RP.green : RP.blue
    }

    private func stateColor(_ title: String) -> Color {
        switch title {
        case TesterState.installed.title: RP.green
        case TesterState.accepted.title: RP.blue
        case TesterState.invited.title: RP.orange
        default: RP.muted
        }
    }
}

private struct ReporterSlice: Identifiable {
    let name: String
    let count: Int
    let color: Color
    var id: String { name }
}

private struct TestersReports: View {
    let report: TestersReport

    private var slices: [ReporterSlice] {
        let onlyComments = report.withComments - report.withBoth
        let onlyCrashes = report.withCrashes - report.withBoth
        let none = report.total - onlyComments - onlyCrashes - report.withBoth
        return [ReporterSlice(name: "Solo comentarios", count: onlyComments, color: RP.blue),
                ReporterSlice(name: "Solo errores", count: onlyCrashes, color: RP.orange),
                ReporterSlice(name: "Ambos", count: report.withBoth, color: RP.pink),
                ReporterSlice(name: "Sin reportes", count: none, color: RP.line)]
            .filter { $0.count > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                KPI(value: report.withComments, label: "Comentaron", color: RP.blue)
                KPI(value: report.withCrashes, label: "Con errores", color: RP.orange)
                KPI(value: report.totalComments, label: "Comentarios", color: RP.cyan)
                KPI(value: report.totalCrashes, label: "Errores", color: RP.pink)
            }
            HStack(alignment: .top, spacing: 14) {
                Card(title: "Testers que reportaron") {
                    HStack(spacing: 12) {
                        Chart(slices) { slice in
                            SectorMark(angle: .value("Testers", slice.count), innerRadius: .ratio(0.62), angularInset: 1.2)
                                .foregroundStyle(slice.color)
                        }
                        .frame(width: 96, height: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(slices) { slice in
                                HStack(spacing: 5) {
                                    Circle().fill(slice.color).frame(width: 7, height: 7)
                                    Text(slice.name).font(.system(size: 9)).foregroundStyle(RP.ink).lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text("\(slice.count)").font(.system(size: 9, weight: .bold)).foregroundStyle(RP.ink).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                Card(title: "Reportes por versión instalada") {
                    if report.reportsByVersion.isEmpty {
                        Text("Sin reportes").font(.system(size: 10)).foregroundStyle(RP.muted)
                    } else {
                        StackedReportRows(bars: report.reportsByVersion)
                    }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                Card(title: "Errores por modelo de iPhone") { RankBars(items: report.crashesByModel, color: RP.orange) }
                Card(title: "Testers con más reportes") {
                    if report.topReporters.isEmpty {
                        Text("Sin datos").font(.system(size: 10)).foregroundStyle(RP.muted)
                    }
                    ForEach(report.topReporters) { row in
                        HStack(spacing: 6) {
                            Text(row.name).font(.system(size: 9.5)).foregroundStyle(RP.ink).lineLimit(1)
                            Spacer(minLength: 4)
                            Label("\(row.comments)", systemImage: "text.bubble").foregroundStyle(RP.blue)
                            Label("\(row.crashes)", systemImage: "exclamationmark.triangle").foregroundStyle(RP.orange)
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if !report.anyReports {
                    Text("Ninguno de estos testers ha enviado comentarios ni errores en el feedback sincronizado.")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(RP.ink)
                }
                Text("En los últimos 30 días TestFlight registró \(report.sessions30) sesiones y \(report.crashes30) cierres inesperados de estos testers.")
                    .font(.system(size: 9.5)).foregroundStyle(RP.ink)
                Text("Los comentarios y errores enviados se cuentan a partir del feedback sincronizado en CuyAppleReport, por correo del tester. Los cierres de 30 días incluyen los que el tester no llegó a enviar.")
                    .font(.system(size: 8.5)).foregroundStyle(RP.muted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RP.faint, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct VersionGroupCard: View {
    let group: VersionGroup
    let total: Int

    private var isInstalled: Bool { group.version != TesterItem.notInstalled }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.version).font(.system(size: 15, weight: .bold)).foregroundStyle(RP.ink).lineLimit(1).minimumScaleFactor(0.7)
                Text("\(group.testers) \(group.testers == 1 ? "tester" : "testers") · \(percent)%")
                    .font(.system(size: 9.5)).foregroundStyle(RP.muted)
                if group.upToDate {
                    Text("Última build").font(.system(size: 8.5, weight: .bold)).foregroundStyle(RP.green)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RP.green.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Label("\(group.comments)", systemImage: "text.bubble").foregroundStyle(RP.blue)
                    Label("\(group.crashes)", systemImage: "exclamationmark.triangle").foregroundStyle(RP.orange)
                }
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
            }
            .frame(width: 120, alignment: .leading)
            if isInstalled {
                column("Modelos de iPhone", group.models, RP.blue)
                column("Versiones de iOS", group.osVersions, RP.purple)
            } else {
                Text("Aún no instalaron la app, así que TestFlight no informa su iPhone ni su iOS.")
                    .font(.system(size: 9.5)).foregroundStyle(RP.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RP.line, lineWidth: 1))
    }

    private var percent: Int {
        total == 0 ? 0 : Int((Double(group.testers) / Double(total) * 100).rounded())
    }

    private func column(_ title: String, _ items: [Ranked], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(RP.muted)
            RankBars(items: items, color: color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TesterTable: View {
    let rows: [TesterRow]
    let showEmail: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Tester").frame(maxWidth: .infinity, alignment: .leading)
                Text("Estado").frame(width: 50, alignment: .leading)
                Text("Versión").frame(width: 78, alignment: .leading)
                Text("iPhone").frame(width: 84, alignment: .leading)
                Text("iOS").frame(width: 28, alignment: .leading)
                Text("Instalada").frame(width: 44, alignment: .leading)
                Text("Ses.").frame(width: 26, alignment: .trailing)
                Text("Com.").frame(width: 24, alignment: .trailing)
                Text("Err.").frame(width: 24, alignment: .trailing)
            }
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(RP.muted)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(RP.faint)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                line(row).background(index.isMultiple(of: 2) ? Color.clear : RP.faint.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
    }

    /// Dos líneas por fila: nombre y correo (si se incluye), versión y build.
    private func line(_ row: TesterRow) -> some View {
        HStack(spacing: 6) {
            twoLines(row.name, showEmail ? row.email : nil).frame(maxWidth: .infinity, alignment: .leading)
            Text(row.state).frame(width: 50, alignment: .leading)
            twoLines(row.version, row.build).frame(width: 78, alignment: .leading)
            Text(row.model).frame(width: 84, alignment: .leading)
            Text(row.os).frame(width: 28, alignment: .leading)
            Text(row.installedDate.map { RP.shortDate($0) } ?? "—").frame(width: 44, alignment: .leading)
            Text("\(row.sessions)").frame(width: 26, alignment: .trailing)
            Text("\(row.comments)").frame(width: 24, alignment: .trailing)
                .foregroundStyle(row.comments > 0 ? RP.blue : RP.ink)
            Text("\(row.crashes)").frame(width: 24, alignment: .trailing)
                .foregroundStyle(row.crashes > 0 ? RP.orange : RP.ink)
        }
        .font(.system(size: 8))
        .foregroundStyle(RP.ink)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: showEmail ? 24 : 20)
    }

    private func twoLines(_ first: String, _ second: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(first)
            if let second { Text(second).font(.system(size: 7)).foregroundStyle(RP.muted).truncationMode(.middle) }
        }
    }
}

/// Instalaciones de una versión: cuántas, cuándo empezó y cuántas en la última semana.
struct AdoptionRow: Identifiable {
    let version: String
    let installs: Int
    let first: Date
    let last: Date
    let last7: Int
    var id: String { version }

    static func rows(_ installs: [InstallItem], limit: Int, now: Date = .now) -> [AdoptionRow] {
        let seven = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        var grouped: [String: (count: Int, first: Date, last: Date, last7: Int)] = [:]
        for install in installs {
            var value = grouped[install.versionKey] ?? (0, install.date, install.date, 0)
            value.count += 1
            value.first = min(value.first, install.date)
            value.last = max(value.last, install.date)
            if install.date >= seven { value.last7 += 1 }
            grouped[install.versionKey] = value
        }
        let rows = grouped.map { AdoptionRow(version: $0.key, installs: $0.value.count, first: $0.value.first,
                                             last: $0.value.last, last7: $0.value.last7) }
        let sorted = rows.sorted { (lhs: AdoptionRow, rhs: AdoptionRow) -> Bool in
            lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending
        }
        return Array(sorted.prefix(limit))
    }
}

private struct TestersEvolution: View {
    let report: TestersReport

    private var colors: [Color] {
        let palette: [Color] = [RP.green, RP.blue, RP.purple, RP.orange, RP.pink, RP.cyan]
        return report.timeline.series.enumerated().map { index, name in
            name == InstallTimeline.others ? RP.muted.opacity(0.5) : palette[index % palette.count]
        }
    }

    var body: some View {
        let timeline = report.timeline
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                KPI(value: timeline.total, label: "Instalaciones", color: RP.blue)
                KPI(value: timeline.last7, label: "Últimos 7 días", color: RP.green)
                KPI(value: timeline.last30, label: "Últimos 30 días", color: RP.purple)
            }
            Card(title: "Testers con cada versión (acumulado)") {
                Chart(timeline.cumulative) { point in
                    LineMark(x: .value("Fecha", point.date, unit: timeline.unit), y: .value("Testers", point.count))
                        .foregroundStyle(by: .value("Versión", point.series))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartForegroundStyleScale(domain: timeline.series, range: colors)
                .chartLegend(position: .top, alignment: .leading)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisValueLabel().foregroundStyle(RP.muted); AxisGridLine().foregroundStyle(RP.line) } }
                .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(RP.muted); AxisGridLine().foregroundStyle(RP.line) } }
                .frame(height: 140)
            }
            Card(title: "Nuevas instalaciones \(timeline.unitTitle)") {
                Chart(timeline.newInstalls) { point in
                    BarMark(x: .value("Fecha", point.date, unit: timeline.unit), y: .value("Instalaciones", point.count))
                        .foregroundStyle(by: .value("Versión", point.series))
                }
                .chartForegroundStyleScale(domain: timeline.series, range: colors)
                .chartLegend(.hidden)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisValueLabel().foregroundStyle(RP.muted) } }
                .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(RP.muted); AxisGridLine().foregroundStyle(RP.line) } }
                .frame(height: 76)
            }
            Card(title: "Adopción por versión") {
                VStack(spacing: 0) {
                    adoptionLine("Versión", "Instalaciones", "Primera", "Última", "7 días", header: true)
                    ForEach(report.adoption.prefix(6)) { row in
                        adoptionLine(row.version, "\(row.installs)", RP.shortDate(row.first), RP.shortDate(row.last), "\(row.last7)", header: false)
                    }
                }
            }
            Text("Fecha en que cada tester instaló la build, según App Store Connect. Apple solo informa la build que cada tester tiene ahora; las anteriores se conservan desde que CuyAppleReport empezó a guardarlas.")
                .font(.system(size: 8.5)).foregroundStyle(RP.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func adoptionLine(_ version: String, _ installs: String, _ first: String, _ last: String, _ week: String, header: Bool) -> some View {
        HStack {
            Text(version).frame(maxWidth: .infinity, alignment: .leading)
            Text(installs).frame(width: 70, alignment: .trailing)
            Text(first).frame(width: 64, alignment: .trailing)
            Text(last).frame(width: 64, alignment: .trailing)
            Text(week).frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 8.5, weight: header ? .bold : .regular))
        .foregroundStyle(header ? RP.muted : RP.ink)
        .lineLimit(1)
        .frame(height: 16)
    }
}

/// Barras apiladas por versión (comentarios + errores), dibujadas a mano para que se lean bien en el PDF.
private struct StackedReportRows: View {
    let bars: [VersionReportBar]

    private struct Row: Identifiable {
        let version: String
        let comments: Int
        let crashes: Int
        var id: String { version }
    }

    private var rows: [Row] {
        var order: [String] = []
        var values: [String: (Int, Int)] = [:]
        for bar in bars {
            if values[bar.version] == nil { order.append(bar.version) }
            var value = values[bar.version] ?? (0, 0)
            if bar.kind == "Errores" { value.1 += bar.count } else { value.0 += bar.count }
            values[bar.version] = value
        }
        return order.map { Row(version: $0, comments: values[$0]?.0 ?? 0, crashes: values[$0]?.1 ?? 0) }
    }

    var body: some View {
        let rows = rows
        let maxTotal = max(rows.map { $0.comments + $0.crashes }.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                legend("Comentarios", RP.blue)
                legend("Errores", RP.orange)
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.version).font(.system(size: 9)).foregroundStyle(RP.ink).lineLimit(1)
                        .frame(width: 62, alignment: .leading)
                    GeometryReader { proxy in
                        let unit = proxy.size.width / CGFloat(maxTotal)
                        HStack(spacing: 1) {
                            if row.comments > 0 { RoundedRectangle(cornerRadius: 2).fill(RP.blue).frame(width: unit * CGFloat(row.comments)) }
                            if row.crashes > 0 { RoundedRectangle(cornerRadius: 2).fill(RP.orange).frame(width: unit * CGFloat(row.crashes)) }
                        }
                    }
                    .frame(height: 9)
                    Text("\(row.comments + row.crashes)").font(.system(size: 9, weight: .semibold)).foregroundStyle(RP.ink)
                        .monospacedDigit().frame(width: 18, alignment: .trailing)
                }
            }
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 9)).foregroundStyle(RP.muted)
        }
    }
}

private struct TestersDaily: View {
    let rows: [DailyInstallRow]

    /// Escala ajustada a los datos, para que se note el crecimiento aunque sea pequeño.
    private var yDomain: ClosedRange<Int> {
        let low = rows.map(\.total).min() ?? 0
        let high = rows.map(\.total).max() ?? 0
        let margin = max(1, (high - low) / 5)
        return max(0, low - margin)...(high + margin)
    }

    var body: some View {
        let chronological = Array(rows.reversed())
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                KPI(value: rows.first?.total ?? 0, label: "Testers con la app hoy", color: RP.blue)
                KPI(value: rows.reduce(0) { $0 + $1.new }, label: "Nuevos en 30 días", color: RP.green)
                KPI(value: rows.reduce(0) { $0 + $1.updated }, label: "Actualizaron en 30 días", color: RP.purple)
            }
            Card(title: "Testers con la app (cada uno cuenta una vez)") {
                Chart(chronological) { row in
                    LineMark(x: .value("Fecha", row.date, unit: .day), y: .value("Testers", row.total))
                        .foregroundStyle(RP.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: yDomain)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisValueLabel().foregroundStyle(RP.muted) } }
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 2)) { _ in AxisValueLabel().foregroundStyle(RP.muted); AxisGridLine().foregroundStyle(RP.line) } }
                .frame(height: 54)
                .clipped()
            }
            VStack(spacing: 0) {
                line("Fecha", "Testers con la app", "Nuevos", "Actualizaron", header: true).background(RP.faint)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    line(row.date.formatted(Date.FormatStyle(locale: RP.locale).weekday(.wide).day().month(.wide)), row.total.formatted(),
                         row.new > 0 ? "+\(row.new)" : "—", row.updated > 0 ? "\(row.updated)" : "—", header: false)
                        .background(index.isMultiple(of: 2) ? Color.clear : RP.faint.opacity(0.6))
                }
            }
            Text("Cada tester se cuenta una vez, desde el día en que instaló por primera vez; vuelve a aparecer solo si ese día cambió de build (Actualizaron). Quien desinstala no se descuenta, porque Apple no informa esa fecha.")
                .font(.system(size: 8)).foregroundStyle(RP.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(_ date: String, _ total: String, _ new: String, _ updated: String, header: Bool) -> some View {
        HStack {
            Text(date).frame(maxWidth: .infinity, alignment: .leading)
            Text(total).frame(width: 110, alignment: .trailing)
            Text(new).frame(width: 70, alignment: .trailing)
                .foregroundStyle(!header && new != "—" ? RP.green : (header ? RP.muted : RP.ink))
            Text(updated).frame(width: 80, alignment: .trailing)
                .foregroundStyle(!header && updated != "—" ? RP.blue : (header ? RP.muted : RP.ink))
        }
        .font(.system(size: 8.5, weight: header ? .bold : .regular))
        .foregroundStyle(header ? RP.muted : RP.ink)
        .monospacedDigit()
        .padding(.horizontal, 6)
        .frame(height: 13)
    }
}
