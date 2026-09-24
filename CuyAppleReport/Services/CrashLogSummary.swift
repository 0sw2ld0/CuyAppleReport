import Foundation

/// Resumen legible de un crash log de Apple (formato de texto de TestFlight / Xcode Organizer).
struct CrashLogSummary: Equatable, Sendable {
    struct Frame: Equatable, Sendable {
        let index: Int
        let image: String
        let symbol: String
        /// La llamada ocurre dentro de la propia app (no en una librería del sistema).
        var isApp = false
    }

    var exceptionType: String?
    var exceptionSubtype: String?
    var terminationReason: String?
    var crashedThread: Int?
    var applicationInfo: String?
    var process: String?
    /// Llamadas del hilo que falló: las primeras y las primeras dentro de la app.
    var frames: [Frame] = []

    /// Explicación en lenguaje sencillo para lectores no técnicos.
    var plainExplanation: String {
        let text = [exceptionType, terminationReason, exceptionSubtype].compactMap { $0 }.joined(separator: " ").uppercased()
        if text.contains("8BADF00D") { return "La app dejó de responder y el sistema la cerró (bloqueo prolongado)." }
        if text.contains("EXC_RESOURCE") { return "La app usó demasiados recursos (CPU o memoria) y el sistema la cerró." }
        if text.contains("JETSAM") || (text.contains("SIGKILL") && text.contains("MEMORY")) {
            return "El sistema cerró la app por falta de memoria."
        }
        if text.contains("EXC_BAD_ACCESS") || text.contains("SIGSEGV") || text.contains("SIGBUS") {
            return "La app intentó usar memoria que ya no existía o no era válida."
        }
        if text.contains("EXC_BREAKPOINT") || text.contains("SIGTRAP") {
            return "La app encontró una situación inesperada en su código (por ejemplo, un dato vacío) y se detuvo."
        }
        if text.contains("EXC_CRASH") || text.contains("SIGABRT") {
            return "La app se cerró a sí misma por un error que no pudo manejar."
        }
        if text.contains("SIGKILL") { return "El sistema cerró la app de forma forzada." }
        return "La app se cerró de forma inesperada."
    }

    init?(log: String) {
        // Solo interesa la parte anterior a la lista de librerías cargadas.
        let head = log.components(separatedBy: "\nBinary Images:").first ?? log
        let lines = head.components(separatedBy: .newlines)

        func value(_ key: String) -> String? {
            guard let line = lines.first(where: { $0.hasPrefix(key + ":") }) else { return nil }
            let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }

        exceptionType = value("Exception Type")
        exceptionSubtype = value("Exception Subtype")
        terminationReason = value("Termination Reason")
        process = value("Process").map { $0.components(separatedBy: " [").first ?? $0 }
        crashedThread = value("Triggered by Thread").flatMap { Int($0.components(separatedBy: .whitespaces).first ?? "") }

        if let start = lines.firstIndex(where: { $0.hasPrefix("Application Specific Information:") }) {
            let info = lines[(start + 1)...].prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(3).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            applicationInfo = info.isEmpty ? nil : String(info.prefix(300))
        }

        // Hilo que falló: "Thread N Crashed:" o, si no aparece, "Thread N:" del Triggered by Thread.
        let header = lines.firstIndex { $0.range(of: #"^Thread \d+ Crashed:"#, options: .regularExpression) != nil }
            ?? crashedThread.flatMap { thread in lines.firstIndex { $0.hasPrefix("Thread \(thread):") } }
        if let header {
            if crashedThread == nil,
               let number = lines[header].components(separatedBy: .whitespaces).dropFirst().first.flatMap({ Int($0) }) {
                crashedThread = number
            }
            var all: [Frame] = []
            for line in lines[(header + 1)...] {
                guard var frame = Self.frame(from: line) else { break }
                frame.isApp = frame.image == process
                all.append(frame)
            }
            // Las 3 primeras llamadas (donde se detuvo) y las 3 primeras dentro de la app (dónde buscar).
            let top = all.prefix(3)
            let app = all.dropFirst(3).filter(\.isApp).prefix(3)
            frames = Array(top) + Array(app)
        }

        if exceptionType == nil, terminationReason == nil, frames.isEmpty { return nil }
    }

    init?(path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        self.init(log: String(decoding: data, as: UTF8.self))
    }

    /// "0   libswiftCore.dylib   0x1a2b… _swift_release_dealloc + 48 (:-1)"
    private static func frame(from line: String) -> Frame? {
        let parts = line.split(maxSplits: 3, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
        guard parts.count == 4, let index = Int(parts[0]), parts[2].hasPrefix("0x") else { return nil }
        var symbol = String(parts[3])
        if let range = symbol.range(of: #"\s*\(:-?\d+\)$"#, options: .regularExpression) { symbol.removeSubrange(range) }
        if symbol.hasPrefix("0x"), let plus = symbol.range(of: " + ") {
            symbol = "sin símbolos + " + symbol[plus.upperBound...]
        }
        return Frame(index: index, image: String(parts[1]), symbol: symbol)
    }
}
