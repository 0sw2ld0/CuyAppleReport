import Charts
import SwiftData
import SwiftUI

struct DashboardView: View {
    let feedback: [Feedback]

    @EnvironmentObject private var appState: AppState
    @Query(sort: \MonitoredApp.name) private var apps: [MonitoredApp]
    @Query(sort: \SyncRun.startedAt, order: .reverse) private var runs: [SyncRun]
    @State private var selectedRange: DashboardRange = .sevenDays

    private var rangeFeedback: [Feedback] {
        let start = Calendar.current.startOfDay(for: Calendar.current.date(
            byAdding: .day,
            value: -(selectedRange.days - 1),
            to: .now
        ) ?? .now)
        return feedback.filter { $0.createdDate >= start }
    }

    private var comments: [Feedback] { rangeFeedback.filter { $0.kind == "Comentario" } }
    private var crashes: [Feedback] { rangeFeedback.filter { $0.kind == "Error" } }
    private var newCount: Int { rangeFeedback.filter { $0.status == FeedbackStatus.new.rawValue }.count }
    private var recentFeedback: [Feedback] { rangeFeedback.sorted { $0.createdDate > $1.createdDate }.prefix(5).map { $0 } }
    private var selectedAppName: String? {
        guard let selectedAppId = appState.selectedAppId else { return nil }
        return apps.first { $0.appleId == selectedAppId }?.name
    }

    private let metricColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                LazyVGrid(columns: metricColumns, spacing: 12) {
                    MetricCard(title: "Comentarios", value: comments.count, caption: "recibidos", symbol: "text.bubble.fill", tint: .blue)
                    MetricCard(title: "Errores", value: crashes.count, caption: "reportes de crash", symbol: "exclamationmark.triangle.fill", tint: DashboardPalette.coral)
                    MetricCard(title: "Nuevos", value: newCount, caption: "por revisar", symbol: "sparkles", tint: .indigo)
                    MetricCard(title: "Últimos \(selectedRange.days) días", value: rangeFeedback.count, caption: "elementos de feedback", symbol: "calendar", tint: .teal)
                }

                DashboardPanel(title: "Actividad de feedback", accessory: {
                    HStack(spacing: 14) {
                        ChartLegend(color: .blue, title: "Comentarios")
                        ChartLegend(color: DashboardPalette.coral, title: "Errores")
                    }
                }) {
                    Chart(chartValues) { value in
                        BarMark(
                            x: .value("Día", value.day, unit: .day),
                            y: .value("Cantidad", value.count)
                        )
                        .foregroundStyle(by: .value("Tipo", value.kind))
                        .position(by: .value("Tipo", value.kind))
                        .cornerRadius(4)
                    }
                    .chartForegroundStyleScale([
                        "Comentarios": Color.blue,
                        "Errores": DashboardPalette.coral
                    ])
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: selectedRange.days > 14 ? 8 : 7)) { _ in
                            AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                            AxisValueLabel().foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 212)
                    .accessibilityLabel("Actividad de comentarios y errores en los últimos \(selectedRange.days) días")
                }

                HStack(alignment: .top, spacing: 14) {
                    devicePanel
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: 330)
                    recentPanel
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Resumen")
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                Text("Feedback de TestFlight · \(selectedAppName ?? "Todas las apps")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 7) {
                Menu {
                    Picker("Periodo", selection: $selectedRange) {
                        ForEach(DashboardRange.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                } label: {
                    Label("Últimos \(selectedRange.days) días", systemImage: "calendar")
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08)))

                if let run = runs.first {
                    Label("Actualizado \(run.startedAt.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 2)
    }

    private var devicePanel: some View {
        DashboardPanel(title: "Errores por dispositivo") {
            if topDevices.isEmpty {
                emptyPanelMessage("Sin errores registrados", symbol: "iphone")
                    .frame(minHeight: 145)
            } else {
                VStack(spacing: 14) {
                    ForEach(topDevices, id: \.name) { item in
                        VStack(spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: deviceSymbol(for: item.name))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(item.name)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(item.count)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(item.count), total: Double(max(topDevices.first?.count ?? 1, 1)))
                                .tint(DashboardPalette.coral)
                                .controlSize(.small)
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 3)
                .frame(minHeight: 145, alignment: .top)
            }
        }
    }

    private var recentPanel: some View {
        DashboardPanel(title: "Feedback reciente", accessory: {
            Button("Ver comentarios") {
                appState.page = .comments
                appState.selectedFeedbackId = nil
            }
            .buttonStyle(.link)
            .font(.caption)
        }) {
            if recentFeedback.isEmpty {
                emptyPanelMessage("Sin feedback en este periodo", symbol: "text.bubble")
                    .frame(minHeight: 145)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentFeedback) { item in
                        Button {
                            appState.selectedFeedbackId = item.appleId
                        } label: {
                            RecentFeedbackRow(item: item)
                        }
                        .buttonStyle(.plain)

                        if item.appleId != recentFeedback.last?.appleId {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .frame(minHeight: 145, alignment: .top)
            }
        }
    }

    private var chartValues: [DayFeedback] {
        let calendar = Calendar.current
        let interval = selectedRange.days > 14 ? max(1, selectedRange.days / 10) : 1
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(selectedRange.days - 1), to: .now) ?? .now)

        return stride(from: 0, to: selectedRange.days, by: interval).flatMap { offset -> [DayFeedback] in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            let nextDay = calendar.date(byAdding: .day, value: min(interval, selectedRange.days - offset), to: day)!
            return [
                DayFeedback(day: day, kind: "Comentarios", count: comments.filter { $0.createdDate >= day && $0.createdDate < nextDay }.count),
                DayFeedback(day: day, kind: "Errores", count: crashes.filter { $0.createdDate >= day && $0.createdDate < nextDay }.count)
            ]
        }
    }

    private var topDevices: [DeviceCount] {
        let counts = Dictionary(grouping: crashes, by: { $0.deviceModel == nil ? "Desconocido" : $0.deviceName })
            .map { DeviceCount(name: $0.key, count: $0.value.count) }
        return Array(counts.sorted { $0.count > $1.count }.prefix(5))
    }

    private func emptyPanelMessage(_ title: String, symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol)
            .font(.caption)
    }

    private func deviceSymbol(for name: String) -> String {
        let normalized = name.lowercased()
        if normalized.contains("ipad") { return "ipad" }
        if normalized.contains("mac") { return "laptopcomputer" }
        if normalized.contains("vision") { return "visionpro" }
        return "iphone"
    }
}

private enum DashboardRange: String, CaseIterable, Identifiable {
    case sevenDays = "7 días"
    case thirtyDays = "30 días"
    case ninetyDays = "90 días"

    var id: String { rawValue }
    var days: Int {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .ninetyDays: 90
        }
    }
}

private struct DayFeedback: Identifiable {
    let day: Date
    let kind: String
    let count: Int
    var id: String { "\(day.timeIntervalSince1970)-\(kind)" }
}

private struct DeviceCount {
    let name: String
    let count: Int
}

private struct MetricCard: View {
    let title: String
    let value: Int
    let caption: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text("\(value)")
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .dashboardCardSurface()
    }
}

private struct DashboardPanel<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCardSurface()
    }
}

private struct ChartLegend: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct RecentFeedbackRow: View {
    let item: Feedback

    private var isCrash: Bool { item.kind == "Error" }
    private var tint: Color { isCrash ? DashboardPalette.coral : .blue }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: isCrash ? "exclamationmark.triangle.fill" : "text.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 29, height: 29)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(item.comment ?? (isCrash ? "Reporte de error" : "Sin comentario"))
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text([item.app?.name, item.deviceModel.map { DeviceNames.marketingName($0) }, item.appVersion.map { "v\($0)" }, item.buildNumber.map { "Build \($0)" }]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(item.createdDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(statusTint(item.status))
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case FeedbackStatus.resolved.rawValue: .green
        case FeedbackStatus.inReview.rawValue: .orange
        case FeedbackStatus.ignored.rawValue: .secondary
        default: .blue
        }
    }
}

private enum DashboardPalette {
    static let coral = Color(red: 0.91, green: 0.36, blue: 0.34)
}

private extension View {
    func dashboardCardSurface() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.025), radius: 8, y: 2)
    }
}
