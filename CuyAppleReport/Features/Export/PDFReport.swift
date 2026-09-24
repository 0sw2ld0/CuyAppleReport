import AppKit
import Charts
import ImageIO
import SwiftUI

// MARK: - Render

/// Informe PDF pensado para lectores no técnicos (marketing, producto, cliente).
/// Cada página es una vista SwiftUI renderizada como vector con un tema claro fijo,
/// para que el resultado no dependa del modo oscuro del Mac.
@MainActor
enum PDFReportRenderer {
    static let pageSize = CGSize(width: 595, height: 842) // A4 en puntos

    static func render(feedback: [Feedback], anonymizeEmails: Bool) throws -> Data {
        let report = ReportModel(feedback: feedback, anonymize: anonymizeEmails)
        let pages = report.pages
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let info = [kCGPDFContextTitle: "Informe de feedback TestFlight",
                    kCGPDFContextCreator: "CuyAppleReport"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else {
            throw ExportError.couldNotCreate
        }
        for (index, page) in pages.enumerated() {
            let view = ReportPageView(page: page, report: report, number: index + 1, total: pages.count)
                .frame(width: pageSize.width, height: pageSize.height)
                .background(RP.paper)
                .environment(\.colorScheme, .light)
                .environment(\.locale, RP.locale)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(pageSize)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return data as Data
    }
}

// MARK: - Datos

/// Paleta fija (no depende del modo claro/oscuro del sistema).
enum RP {
    static let paper = Color.white
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let muted = Color(red: 0.43, green: 0.43, blue: 0.45)
    static let faint = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let line = Color(red: 0.90, green: 0.90, blue: 0.92)
    static let cyan = Color(red: 0.13, green: 0.76, blue: 0.93)
    static let blue = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let purple = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let pink = Color(red: 0.93, green: 0.28, blue: 0.60)
    static let orange = Color(red: 0.98, green: 0.45, blue: 0.09)
    static let green = Color(red: 0.13, green: 0.70, blue: 0.40)
    static let locale = Locale(identifier: "es_PE")
    static let brand = LinearGradient(colors: [cyan, blue, purple, pink], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func date(_ date: Date, _ dateStyle: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle = .omitted) -> String {
        date.formatted(Date.FormatStyle(date: dateStyle, time: time, locale: locale))
    }

    static func status(_ status: String) -> Color {
        switch status {
        case FeedbackStatus.resolved.rawValue: green
        case FeedbackStatus.inReview.rawValue: orange
        case FeedbackStatus.ignored.rawValue: muted
        default: blue
        }
    }
}

struct ReportItem: Identifiable {
    let id: String
    let number: Int
    let isCrash: Bool
    let date: Date
    let comment: String?
    let tester: String
    let device: String
    let deviceCode: String?
    let os: String?
    let version: String?
    let build: String?
    let status: String
    let appName: String
    let screenshots: [String]
    let crash: CrashLogSummary?

    var crashType: String? { crash?.exceptionType }

    var versionLabel: String? {
        switch (version, build) {
        case let (v?, b?): "v\(v) (\(b))"
        case let (v?, nil): "v\(v)"
        case let (nil, b?): "Build \(b)"
        default: nil
        }
    }
}

enum ReportPage {
    case cover
    case summary
    case comments([ReportItem], isFirst: Bool)
    case crashes([ReportItem], isFirst: Bool)
}

struct Ranked: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

struct DayCount: Identifiable {
    let date: Date
    let kind: String
    let count: Int
    var id: String { "\(date.timeIntervalSince1970)-\(kind)" }
}

struct ReportModel {
    let comments: [ReportItem]
    let crashes: [ReportItem]
    let appNames: String
    let firstDate: Date?
    let lastDate: Date?
    let testers: Int
    let devices: Int
    let newCount: Int
    let activity: [DayCount]
    let activityUnit: Calendar.Component
    let topDevices: [Ranked]
    let versions: [Ranked]
    let statuses: [Ranked]
    let crashTypes: [Ranked]

    var total: Int { comments.count + crashes.count }

    init(feedback: [Feedback], anonymize: Bool) {
        let sorted = feedback.sorted { $0.createdDate > $1.createdDate }
        var commentNumber = 0
        var crashNumber = 0
        let items: [ReportItem] = sorted.map { item in
            let isCrash = item.kind == "Error"
            if isCrash { crashNumber += 1 } else { commentNumber += 1 }
            let crash: CrashLogSummary? = isCrash ? item.crashLogPath.flatMap { CrashLogSummary(path: $0) } : nil
            return ReportItem(
                id: item.appleId, number: isCrash ? crashNumber : commentNumber, isCrash: isCrash,
                date: item.createdDate, comment: item.comment?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                tester: Self.tester(item, anonymize: anonymize),
                device: DeviceNames.marketingName(item.deviceModel), deviceCode: item.deviceModel,
                os: item.osVersion, version: item.appVersion, build: item.buildNumber, status: item.status,
                appName: item.app?.name ?? "App", screenshots: item.orderedScreenshotPaths, crash: crash)
        }
        comments = items.filter { !$0.isCrash }
        crashes = items.filter(\.isCrash)
        appNames = Array(Set(items.map(\.appName))).sorted().joined(separator: " · ")
        firstDate = items.map(\.date).min()
        lastDate = items.map(\.date).max()
        testers = Set(feedback.compactMap { $0.testerEmail?.lowercased() }).count
        devices = Set(feedback.compactMap(\.deviceModel)).count
        newCount = feedback.filter { $0.status == FeedbackStatus.new.rawValue }.count

        let span = (lastDate ?? .now).timeIntervalSince(firstDate ?? .now)
        activityUnit = span > 60 * 86_400 ? .weekOfYear : .day
        let calendar = Calendar.current
        let unit = activityUnit
        func bucket(_ date: Date) -> Date {
            unit == .day ? calendar.startOfDay(for: date)
                : calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        }
        var counts: [Date: [String: Int]] = [:]
        for item in items {
            let kind = item.isCrash ? "Errores" : "Comentarios"
            counts[bucket(item.date), default: [:]][kind, default: 0] += 1
        }
        var points: [DayCount] = []
        for (date, kinds) in counts {
            for (kind, count) in kinds { points.append(DayCount(date: date, kind: kind, count: count)) }
        }
        activity = points.sorted { $0.date < $1.date }
        topDevices = Self.rank(items.map(\.device), limit: 6)
        versions = Self.rank(items.map { $0.version.map { "v\($0)" } ?? "Sin versión" }, limit: 6)
        statuses = Self.rank(items.map(\.status), limit: 4)
        crashTypes = Self.rank(crashes.map { $0.crashType ?? "Sin detalle" }, limit: 5)
    }

    var pages: [ReportPage] {
        var pages: [ReportPage] = [.cover, .summary]
        // Reparte las tarjetas según su altura estimada para que nunca se salgan de la página.
        var current: [ReportItem] = []
        var used: CGFloat = 0
        var isFirst = true
        for item in comments {
            let height = CommentCard.estimatedHeight(item)
            let budget: CGFloat = isFirst ? 640 : 680
            if !current.isEmpty, used + 14 + height > budget {
                pages.append(.comments(current, isFirst: isFirst))
                isFirst = false
                current = []
                used = 0
            }
            used += (current.isEmpty ? 0 : 14) + height
            current.append(item)
        }
        if !current.isEmpty { pages.append(.comments(current, isFirst: isFirst)) }
        // Errores: la primera página lleva además el resumen (unos 170 puntos).
        current = []
        used = 0
        isFirst = true
        for item in crashes {
            let height = CrashCard.estimatedHeight(item)
            let budget: CGFloat = isFirst ? 455 : 680
            if !current.isEmpty, used + 14 + height > budget {
                pages.append(.crashes(current, isFirst: isFirst))
                isFirst = false
                current = []
                used = 0
            }
            used += (current.isEmpty ? 0 : 14) + height
            current.append(item)
        }
        if !current.isEmpty { pages.append(.crashes(current, isFirst: isFirst)) }
        return pages
    }

    var rangeText: String {
        guard let firstDate, let lastDate else { return "Sin datos" }
        let first = RP.date(firstDate, .long)
        let last = RP.date(lastDate, .long)
        return first == last ? first : "\(first) – \(last)"
    }

    private static func rank(_ values: [String], limit: Int) -> [Ranked] {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        let ranked: [Ranked] = counts.map { Ranked(name: $0.key, count: $0.value) }
        let sorted = ranked.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.name < rhs.name : lhs.count > rhs.count
        }
        return Array(sorted.prefix(limit))
    }

    private static func tester(_ item: Feedback, anonymize: Bool) -> String {
        if anonymize {
            guard let email = item.testerEmail, let at = email.firstIndex(of: "@") else { return "Tester" }
            return "tester\(email[at...])"
        }
        return item.testerName?.nilIfEmpty ?? item.testerEmail ?? "Tester"
    }

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}


private enum ReportImages {
    /// Miniatura para el PDF (limita el tamaño del archivo y la memoria).
    static func load(_ path: String, maxPixel: Int = 900) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Páginas

private struct ReportPageView: View {
    let page: ReportPage
    let report: ReportModel
    let number: Int
    let total: Int

    var body: some View {
        switch page {
        case .cover:
            CoverPage(report: report)
        case .summary:
            PageScaffold(report: report, number: number, total: total,
                         eyebrow: "RESUMEN", title: "Así va el feedback de los testers") { SummaryContent(report: report) }
        case .comments(let items, let isFirst):
            PageScaffold(report: report, number: number, total: total,
                         eyebrow: "COMENTARIOS", title: isFirst ? "Lo que dicen los testers" : nil) {
                VStack(spacing: 14) {
                    ForEach(items) { CommentCard(item: $0, total: report.comments.count) }
                    Spacer(minLength: 0)
                }
            }
        case .crashes(let items, let isFirst):
            PageScaffold(report: report, number: number, total: total,
                         eyebrow: "ESTABILIDAD", title: isFirst ? "Errores reportados" : nil) {
                CrashesContent(items: items, report: report, showSummary: isFirst)
            }
        }
    }
}

private struct PageScaffold<Content: View>: View {
    let report: ReportModel
    let number: Int
    let total: Int
    let eyebrow: String
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image("CuyAppleReportMark").resizable().scaledToFill()
                    .frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 5))
                Text("CuyAppleReport").font(.system(size: 10, weight: .semibold)).foregroundStyle(RP.ink)
                Text("Informe TestFlight").font(.system(size: 10)).foregroundStyle(RP.muted)
                Spacer()
                Text(report.appNames).font(.system(size: 10, weight: .medium)).foregroundStyle(RP.muted).lineLimit(1)
            }
            Rectangle().fill(RP.brand).frame(height: 2).padding(.top, 10)

            Text(eyebrow).font(.system(size: 9, weight: .bold)).tracking(1.6).foregroundStyle(RP.blue).padding(.top, 20)
            if let title {
                Text(title).font(.system(size: 24, weight: .bold)).foregroundStyle(RP.ink).padding(.top, 4).padding(.bottom, 16)
            } else {
                Spacer().frame(height: 12)
            }

            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack {
                Text("Confidencial · Preparado con CuyAppleReport").foregroundStyle(RP.muted)
                Spacer()
                Text("\(number) / \(total)").foregroundStyle(RP.muted).monospacedDigit()
            }
            .font(.system(size: 8.5))
            .padding(.top, 10)
        }
        .padding(.horizontal, 40)
        .padding(.top, 32)
        .padding(.bottom, 24)
    }
}

private struct CoverPage: View {
    let report: ReportModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                RP.brand
                Circle().fill(.white.opacity(0.10)).frame(width: 360).offset(x: 330, y: -210)
                Circle().fill(.white.opacity(0.08)).frame(width: 220).offset(x: 420, y: 10)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image("CuyAppleReportMark").resizable().scaledToFill()
                            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.6), lineWidth: 1))
                        Text("CuyAppleReport").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    }
                    Spacer()
                    Text("INFORME DE FEEDBACK · TESTFLIGHT").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.85))
                    Text(report.appNames.isEmpty ? "Feedback de testers" : report.appNames)
                        .font(.system(size: 40, weight: .heavy)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                    Text(report.rangeText).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                }
                .padding(44)
            }
            .frame(height: 470)
            .clipped()

            VStack(alignment: .leading, spacing: 22) {
                Text("En cifras").font(.system(size: 12, weight: .bold)).foregroundStyle(RP.muted)
                HStack(spacing: 12) {
                    KPI(value: report.comments.count, label: "Comentarios", color: RP.blue)
                    KPI(value: report.crashes.count, label: "Errores", color: RP.orange)
                    KPI(value: report.testers, label: "Testers", color: RP.purple)
                    KPI(value: report.devices, label: "Dispositivos", color: RP.pink)
                }
                if let quote = report.comments.first?.comment {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Comentario más reciente").font(.system(size: 10, weight: .semibold)).foregroundStyle(RP.muted)
                        Text("“\(quote)”").font(.system(size: 14, weight: .medium)).italic().foregroundStyle(RP.ink).lineLimit(3)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RP.faint, in: RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
                HStack {
                    Text("Generado el \(RP.date(.now, .long, time: .shortened))")
                    Spacer()
                    Text("Confidencial")
                }
                .font(.system(size: 9)).foregroundStyle(RP.muted)
            }
            .padding(.horizontal, 44)
            .padding(.top, 30)
            .padding(.bottom, 28)
        }
    }
}

private struct KPI: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(color).frame(width: 22, height: 4)
            Text("\(value)").font(.system(size: 28, weight: .bold)).foregroundStyle(RP.ink).monospacedDigit()
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(RP.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RP.faint, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SummaryContent: View {
    let report: ReportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                KPI(value: report.total, label: "Elementos de feedback", color: RP.cyan)
                KPI(value: report.newCount, label: "Sin revisar", color: RP.blue)
                KPI(value: report.comments.reduce(0) { $0 + $1.screenshots.count }, label: "Capturas", color: RP.purple)
            }

            Card(title: report.activityUnit == .day ? "Actividad por día" : "Actividad por semana") {
                Chart(report.activity) { point in
                    BarMark(x: .value("Fecha", point.date, unit: report.activityUnit), y: .value("Cantidad", point.count))
                        .foregroundStyle(by: .value("Tipo", point.kind))
                        .cornerRadius(3)
                }
                .chartForegroundStyleScale(["Comentarios": RP.blue, "Errores": RP.orange])
                .chartLegend(position: .top, alignment: .trailing)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisValueLabel().foregroundStyle(RP.muted); AxisGridLine().foregroundStyle(RP.line) } }
                .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(RP.muted); AxisGridLine().foregroundStyle(RP.line) } }
                .frame(height: 150)
            }

            HStack(alignment: .top, spacing: 14) {
                Card(title: "Dispositivos más usados") { RankBars(items: report.topDevices, color: RP.blue) }
                Card(title: "Versiones de la app") { RankBars(items: report.versions, color: RP.purple) }
            }

            Card(title: "Estado del seguimiento") {
                HStack(spacing: 8) {
                    ForEach(report.statuses) { status in
                        HStack(spacing: 6) {
                            Circle().fill(RP.status(status.name)).frame(width: 7, height: 7)
                            Text(status.name).font(.system(size: 10)).foregroundStyle(RP.ink)
                            Text("\(status.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(RP.ink)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RP.faint, in: Capsule())
                    }
                    Spacer()
                }
            }
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(RP.ink)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RP.line, lineWidth: 1))
    }
}

private struct RankBars: View {
    let items: [Ranked]
    let color: Color

    var body: some View {
        let maxCount = max(items.map(\.count).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 7) {
            if items.isEmpty {
                Text("Sin datos").font(.system(size: 10)).foregroundStyle(RP.muted)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.name).font(.system(size: 9.5)).foregroundStyle(RP.ink).lineLimit(1)
                        Spacer()
                        Text("\(item.count)").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(RP.ink).monospacedDigit()
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(RP.faint)
                            Capsule().fill(color).frame(width: max(4, proxy.size.width * CGFloat(item.count) / CGFloat(maxCount)))
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
    }
}

private struct CommentCard: View {
    let item: ReportItem
    let total: Int
    nonisolated static let commentLines = 4

    /// Altura aproximada de la tarjeta (para paginar antes de renderizar).
    nonisolated static func estimatedHeight(_ item: ReportItem) -> CGFloat {
        let characters = Double(item.comment?.count ?? 24)
        let lines = min(commentLines, max(1, Int((characters / 60).rounded(.up))))
        var height: CGFloat = 32 + 20 + 12 + CGFloat(lines) * 19 + 12 + 22
        if !item.screenshots.isEmpty { height += 12 + ScreenshotStrip.height }
        return height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("#\(item.number)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RP.brand, in: Capsule())
                Text(RP.date(item.date, .long, time: .shortened)).font(.system(size: 10)).foregroundStyle(RP.muted)
                Spacer()
                StatusPill(status: item.status)
            }

            Text(item.comment.map { "“\($0)”" } ?? "Sin comentario escrito")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(item.comment == nil ? RP.muted : RP.ink)
                .lineLimit(Self.commentLines)
                .fixedSize(horizontal: false, vertical: true)

            FlowChips(values: [item.device, item.os.map { "iOS \($0)" }, item.versionLabel, item.tester].compactMap { $0 })

            if !item.screenshots.isEmpty {
                ScreenshotStrip(paths: item.screenshots)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(RP.paper))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RP.line, lineWidth: 1))
    }
}

private struct ScreenshotStrip: View {
    let paths: [String]
    nonisolated static let height: CGFloat = 180
    private var height: CGFloat { Self.height }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(paths.prefix(4).enumerated()), id: \.offset) { offset, path in
                if let image = ReportImages.load(path) {
                    let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(height: height)
                        .frame(maxWidth: aspect > 1 ? 250 : height * aspect)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RP.line, lineWidth: 1))
                        .overlay(alignment: .bottomTrailing) {
                            if offset == 3, paths.count > 4 {
                                Text("+\(paths.count - 4)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.black.opacity(0.6), in: Capsule()).padding(6)
                            }
                        }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: height)
    }
}

private struct StatusPill: View {
    let status: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(RP.status(status)).frame(width: 6, height: 6)
            Text(status).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(RP.status(status))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RP.status(status).opacity(0.1), in: Capsule())
    }
}

private struct FlowChips: View {
    let values: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { value in
                Text(value).font(.system(size: 9.5)).foregroundStyle(RP.ink).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RP.faint, in: Capsule())
            }
        }
    }
}

private struct CrashesContent: View {
    let items: [ReportItem]
    let report: ReportModel
    let showSummary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showSummary {
                HStack(alignment: .top, spacing: 14) {
                    KPI(value: report.crashes.count, label: "Errores reportados", color: RP.orange)
                        .frame(width: 150)
                    Card(title: "Tipos de error más frecuentes") { RankBars(items: report.crashTypes, color: RP.orange) }
                }
            }
            ForEach(items) { CrashCard(item: $0) }
            Spacer(minLength: 0)
        }
    }
}

/// Tarjeta de un error: qué pasó en lenguaje sencillo, datos técnicos y dónde falló.
private struct CrashCard: View {
    let item: ReportItem

    /// Altura aproximada (para paginar antes de renderizar).
    nonisolated static func estimatedHeight(_ item: ReportItem) -> CGFloat {
        var height: CGFloat = 32 + 20 + 10 + 22 + 10 + 46   // cabecera, chips y explicación
        if let comment = item.comment {
            height += 10 + CGFloat(min(3, max(1, Int((Double(comment.count) / 60).rounded(.up))))) * 19
        }
        if let crash = item.crash {
            height += 10 + 16 * CGFloat([crash.terminationReason, crash.exceptionSubtype].compactMap { $0 }.count + 1)
            if !crash.frames.isEmpty { height += 10 + 22 + CGFloat(crash.frames.count) * 13 }
        }
        return height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Error #\(item.number)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RP.orange, in: Capsule())
                Text(RP.date(item.date, .long, time: .shortened)).font(.system(size: 10)).foregroundStyle(RP.muted)
                Spacer()
                StatusPill(status: item.status)
            }

            FlowChips(values: [item.device, item.os.map { "iOS \($0)" }, item.versionLabel, item.tester].compactMap { $0 })

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(RP.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.crash?.plainExplanation ?? "La app se cerró de forma inesperada.")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(RP.ink)
                    Text(item.crash?.exceptionType ?? "Sin crash log descargado")
                        .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(RP.muted)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RP.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            if let comment = item.comment {
                Text("“\(comment)”").font(.system(size: 12)).italic().foregroundStyle(RP.ink).lineLimit(3)
            }

            if let crash = item.crash {
                VStack(alignment: .leading, spacing: 4) {
                    detail("Motivo del cierre", crash.terminationReason)
                    detail("Subtipo", crash.exceptionSubtype)
                    detail("Hilo que falló", crash.crashedThread.map { "Hilo \($0)" })
                }
                if !crash.frames.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dónde falló (llamadas del hilo)").font(.system(size: 9, weight: .semibold)).foregroundStyle(RP.muted)
                        ForEach(Array(crash.frames.enumerated()), id: \.offset) { _, frame in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(frame.index)").frame(width: 18, alignment: .trailing).foregroundStyle(RP.muted)
                                Text(frame.image).frame(width: 118, alignment: .leading).truncationMode(.middle)
                                    .foregroundStyle(frame.isApp ? RP.blue : RP.ink)
                                    .fontWeight(frame.isApp ? .semibold : .regular)
                                Text(frame.symbol).foregroundStyle(RP.ink).truncationMode(.middle)
                            }
                            .font(.system(size: 8.5, design: .monospaced))
                            .lineLimit(1)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RP.faint, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(RP.paper))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RP.line, lineWidth: 1))
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String?) -> some View {
        if let value {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.system(size: 9.5)).foregroundStyle(RP.muted).frame(width: 100, alignment: .leading)
                Text(value).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(RP.ink).lineLimit(1)
            }
        }
    }
}
