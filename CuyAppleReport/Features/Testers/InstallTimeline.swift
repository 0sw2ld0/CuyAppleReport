import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Una instalación de una build por un tester, ya preparada para dibujar.
struct InstallItem: Hashable {
    let testerRecordId: String
    let versionKey: String
    let date: Date
}

/// Curvas de instalaciones por versión: acumulado y nuevas por día o por semana.
struct InstallTimeline {
    enum Period: String, CaseIterable, Identifiable {
        case days30 = "30 días"
        case days90 = "90 días"
        case year = "1 año"
        case all = "Todo"
        var id: String { rawValue }

        var days: Int? {
            switch self {
            case .days30: 30
            case .days90: 90
            case .year: 365
            case .all: nil
            }
        }
    }

    struct Point: Identifiable {
        let date: Date
        let series: String
        let count: Int
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    static let others = "Otras"

    let cumulative: [Point]
    let newInstalls: [Point]
    let unit: Calendar.Component
    let series: [String]
    let total: Int
    let last7: Int
    let last30: Int
    let start: Date
    let end: Date

    /// `maxSeries` versiones más recientes con su propia curva; el resto se suma en "Otras".
    init(installs: [InstallItem], period: Period, maxSeries: Int = 5, now: Date = .now) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let firstDate = installs.map(\.date).min().map { calendar.startOfDay(for: $0) } ?? today
        let start: Date = if let days = period.days {
            max(calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today, firstDate)
        } else {
            firstDate
        }
        let spanDays = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        let unit: Calendar.Component = spanDays > 120 ? .weekOfYear : .day
        self.unit = unit
        self.start = start
        end = today

        // Versiones con instalaciones dentro del periodo, de la más reciente a la más antigua.
        var inPeriod: Set<String> = []
        for install in installs where install.date >= start { inPeriod.insert(install.versionKey) }
        let ordered = inPeriod.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        let named = Array(ordered.prefix(maxSeries))
        let namedSet = Set(named)
        series = ordered.count > maxSeries ? named + [Self.others] : named

        func bucket(_ date: Date) -> Date {
            let day = calendar.startOfDay(for: date)
            guard unit == .weekOfYear else { return day }
            return calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        }
        func seriesName(_ key: String) -> String { namedSet.contains(key) ? key : Self.others }

        var buckets: [Date] = []
        var cursor = bucket(start)
        while cursor <= today {
            buckets.append(cursor)
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor) else { break }
            cursor = next
        }

        // Base: lo instalado antes del periodo, para que el acumulado no empiece en cero.
        var base: [String: Int] = [:]
        var perBucket: [String: [Date: Int]] = [:]
        var last7 = 0, last30 = 0
        let seven = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let thirty = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        for install in installs {
            if install.date >= seven { last7 += 1 }
            if install.date >= thirty { last30 += 1 }
            guard inPeriod.contains(install.versionKey) else { continue }
            let name = seriesName(install.versionKey)
            if install.date < start {
                base[name, default: 0] += 1
            } else {
                perBucket[name, default: [:]][bucket(install.date), default: 0] += 1
            }
        }
        var cumulative: [Point] = []
        var newInstalls: [Point] = []
        for name in series {
            var running = base[name] ?? 0
            let counts = perBucket[name] ?? [:]
            for date in buckets {
                let added = counts[date] ?? 0
                running += added
                cumulative.append(Point(date: date, series: name, count: running))
                if added > 0 { newInstalls.append(Point(date: date, series: name, count: added)) }
            }
        }
        self.cumulative = cumulative
        self.newInstalls = newInstalls
        total = installs.count
        self.last7 = last7
        self.last30 = last30
    }

    var isEmpty: Bool { series.isEmpty }
    var unitTitle: String { unit == .day ? "por día" : "por semana" }
}

/// Un día del resumen diario: testers con la app hasta ese día (cada uno cuenta una vez),
/// los que la instalaron por primera vez y los que cambiaron de build ese día.
struct DailyInstallRow: Identifiable {
    let date: Date
    let total: Int
    let new: Int
    let updated: Int
    var id: Date { date }

    /// Últimos `days` días, del más reciente al más antiguo. Un tester se cuenta de nuevo solo
    /// si ese día instaló otra build (una actualización); repetir la misma no suma.
    static func rows(_ installs: [InstallItem], days: Int = 30, now: Date = .now) -> [DailyInstallRow] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var firstByTester: [String: Date] = [:]
        for install in installs {
            firstByTester[install.testerRecordId] = min(firstByTester[install.testerRecordId] ?? install.date, install.date)
        }
        var newByDay: [Date: Int] = [:]
        var firstDays: [Date] = []
        for first in firstByTester.values {
            let day = calendar.startOfDay(for: first)
            newByDay[day, default: 0] += 1
            firstDays.append(day)
        }
        var updatedByDay: [Date: Set<String>] = [:]
        for install in installs where install.date > (firstByTester[install.testerRecordId] ?? install.date) {
            updatedByDay[calendar.startOfDay(for: install.date), default: []].insert(install.testerRecordId)
        }
        firstDays.sort()
        var rows: [DailyInstallRow] = []
        var index = 0
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var day = start
        while day <= today {
            while index < firstDays.count, firstDays[index] <= day { index += 1 }
            rows.append(DailyInstallRow(date: day, total: index, new: newByDay[day] ?? 0,
                                        updated: updatedByDay[day]?.count ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return rows.reversed()
    }

    static func csv(_ rows: [DailyInstallRow]) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let lines = ["fecha,testers_con_la_app,nuevos,actualizaron"] + rows.map {
            "\(formatter.string(from: $0.date)),\($0.total),\($0.new),\($0.updated)"
        }
        return Data([0xEF, 0xBB, 0xBF] + Array(lines.joined(separator: "\r\n").utf8))
    }
}

/// Panel "Evolución de instalaciones" de la sección Testers.
struct InstallTimelinePanel: View {
    let installs: [InstallItem]
    @State private var period: InstallTimeline.Period = .days90
    @State private var mode: Mode = .cumulative
    @State private var showExporter = false

    enum Mode: String, CaseIterable, Identifiable {
        case cumulative = "Acumulado"
        case new = "Nuevas"
        case daily = "Diario 30 d"
        var id: String { rawValue }
    }

    var body: some View {
        let timeline = InstallTimeline(installs: installs, period: period)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Evolución de instalaciones").font(.headline)
                Text("\(timeline.last7.formatted()) en 7 días · \(timeline.last30.formatted()) en 30 días")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Vista", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 270)
                if mode == .daily {
                    Button { showExporter = true } label: { Label("Exportar CSV", systemImage: "square.and.arrow.up") }
                } else {
                    Picker("Periodo", selection: $period) {
                        ForEach(InstallTimeline.Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 250)
                }
            }
            if mode == .daily {
                DailyInstallsTable(rows: DailyInstallRow.rows(installs))
            } else if timeline.isEmpty {
                Text("No hay instalaciones en este periodo.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mode == .cumulative {
                Chart(timeline.cumulative) { point in
                    LineMark(x: .value("Fecha", point.date, unit: timeline.unit), y: .value("Testers", point.count))
                        .foregroundStyle(by: .value("Versión", point.series))
                        .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale(domain: timeline.series, range: Self.palette(timeline.series))
                .chartLegend(position: .trailing, alignment: .top)
            } else {
                Chart(timeline.newInstalls) { point in
                    BarMark(x: .value("Fecha", point.date, unit: timeline.unit), y: .value("Instalaciones", point.count))
                        .foregroundStyle(by: .value("Versión", point.series))
                }
                .chartForegroundStyleScale(domain: timeline.series, range: Self.palette(timeline.series))
                .chartLegend(position: .trailing, alignment: .top)
            }
            Text("Fecha en que cada tester instaló su build, según App Store Connect. Apple solo informa la build instalada ahora; las anteriores se van guardando en cada sincronización.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.arguments.contains("--mode-daily") { mode = .daily } }
        #endif
        .fileExporter(isPresented: $showExporter,
                      document: ExportFile(data: DailyInstallRow.csv(DailyInstallRow.rows(installs)), contentType: .commaSeparatedText),
                      contentType: .commaSeparatedText,
                      defaultFilename: "CuyAppleReport_Testers_diario_\(Date.now.formatted(.iso8601.year().month().day()))") { _ in }
    }

    static func palette(_ series: [String]) -> [Color] {
        let colors: [Color] = [.green, .blue, .purple, .orange, .pink, .teal]
        return series.enumerated().map { index, name in
            name == InstallTimeline.others ? Color.gray.opacity(0.6) : colors[index % colors.count]
        }
    }
}

/// Tabla de los últimos 30 días: testers con la app hasta ese día, nuevos y actualizaciones.
private struct DailyInstallsTable: View {
    let rows: [DailyInstallRow]

    var body: some View {
        Table(rows) {
            TableColumn("Fecha") { row in
                Text(row.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
            }
            TableColumn("Testers con la app") { row in
                Text(row.total.formatted()).monospacedDigit().fontWeight(.semibold)
            }
            TableColumn("Nuevos") { row in
                Text(row.new > 0 ? "+\(row.new.formatted())" : "—").monospacedDigit()
                    .foregroundStyle(row.new > 0 ? Color.green : Color.secondary)
            }
            TableColumn("Actualizaron") { row in
                Text(row.updated > 0 ? row.updated.formatted() : "—").monospacedDigit()
                    .foregroundStyle(row.updated > 0 ? Color.blue : Color.secondary)
            }
        }
    }
}
