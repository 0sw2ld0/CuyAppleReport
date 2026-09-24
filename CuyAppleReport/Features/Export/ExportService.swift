import AppKit
import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv = "CSV"
    case xlsx = "Excel (.xlsx)"
    case pdf = "PDF"
    var id: String { rawValue }
    var fileExtension: String {
        switch self { case .csv: "csv"; case .xlsx: "xlsx"; case .pdf: "pdf" }
    }
}

enum ExportService {
    @MainActor
    static func data(for format: ExportFormat, feedback: [Feedback], anonymizeEmails: Bool) throws -> Data {
        switch format {
        case .csv: csv(feedback, anonymizeEmails: anonymizeEmails)
        case .xlsx: try xlsx(feedback, anonymizeEmails: anonymizeEmails)
        case .pdf: try pdf(feedback, anonymizeEmails: anonymizeEmails)
        }
    }

    private static func csv(_ feedback: [Feedback], anonymizeEmails: Bool) -> Data {
        let headers = ["id", "tipo", "fecha", "app", "version", "build", "tester_email", "tester_nombre", "dispositivo", "os", "idioma", "comentario", "estado", "notas", "capturas"]
        let rows = feedback.map { item in
            [item.appleId, item.kind, ISO8601DateFormatter().string(from: item.createdDate), item.app?.name ?? "",
             item.appVersion ?? "", item.buildNumber ?? "", email(item.testerEmail, anonymize: anonymizeEmails),
             item.testerName ?? "", item.deviceModel ?? "", item.osVersion ?? "", item.locale ?? "",
             item.comment ?? "", item.status, item.notes, item.screenshotPaths.joined(separator: " | ")]
        }
        let body = ([headers] + rows).map { $0.map(escapeCSV).joined(separator: ",") }.joined(separator: "\r\n")
        return Data(([UInt8(0xEF), 0xBB, 0xBF] + Array(body.utf8)))
    }

    private static func xlsx(_ feedback: [Feedback], anonymizeEmails: Bool) throws -> Data {
        try XLSXWriter.make(feedback: feedback, anonymizeEmails: anonymizeEmails)
    }

    @MainActor
    private static func pdf(_ feedback: [Feedback], anonymizeEmails: Bool) throws -> Data {
        try PDFReportRenderer.render(feedback: feedback, anonymizeEmails: anonymizeEmails)
    }

    private static func email(_ value: String?, anonymize: Bool) -> String {
        guard anonymize, let value, let at = value.firstIndex(of: "@") else { return value ?? "" }
        return "tester\(value[at...])"
    }

    private static func escapeCSV(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

enum ExportError: LocalizedError {
    case couldNotCreate
    var errorDescription: String? { "No se pudo crear el archivo de exportación." }
}
