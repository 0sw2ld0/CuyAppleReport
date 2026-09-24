import Foundation

/// Estado visible de una sincronización en curso.
struct SyncProgress: Equatable, Sendable {
    enum Phase: Int, CaseIterable, Sendable {
        case connecting, comments, images, crashes, saving, done, failed

        /// Pasos que se muestran en la tarjeta de progreso.
        static let steps: [Phase] = [.connecting, .comments, .images, .crashes]

        var title: String {
            switch self {
            case .connecting: "Verificando conexión"
            case .comments: "Buscando comentarios"
            case .images: "Descargando capturas"
            case .crashes: "Buscando errores"
            case .saving: "Guardando"
            case .done: "Sincronización completa"
            case .failed: "No se pudo sincronizar"
            }
        }

        var shortTitle: String {
            switch self {
            case .connecting: "Conexión"
            case .comments: "Comentarios"
            case .images: "Capturas"
            case .crashes: "Errores"
            case .saving: "Guardando"
            case .done: "Listo"
            case .failed: "Error"
            }
        }

        var symbol: String {
            switch self {
            case .connecting: "person.badge.key"
            case .comments: "text.bubble"
            case .images: "photo.on.rectangle.angled"
            case .crashes: "exclamationmark.triangle"
            case .saving: "internaldrive"
            case .done: "checkmark.circle.fill"
            case .failed: "xmark.octagon.fill"
            }
        }
    }

    var phase: Phase = .connecting
    var appName: String?
    var appIndex = 0
    var appCount = 0
    var found = 0
    var newItems = 0
    var imagesDone = 0
    var imagesTotal = 0
    var errorMessage: String?
    var sessionExpired = false
    /// Paso en el que estaba la sincronización cuando falló.
    var lastStep: Phase = .connecting

    mutating func fail(_ message: String, sessionExpired: Bool = false) {
        if !isFinished { lastStep = phase }
        phase = .failed
        errorMessage = message
        self.sessionExpired = sessionExpired
    }

    var isFinished: Bool { phase == .done || phase == .failed }

    /// Progreso total de 0 a 1: cada app pesa lo mismo y, dentro de ella,
    /// las capturas ocupan la mayor parte porque es lo más lento.
    var fraction: Double {
        switch phase {
        case .done: return 1
        case .failed: return max(0.05, base)
        case .connecting: return 0.03
        case .saving: return 0.98
        default: return base
        }
    }

    private var base: Double {
        guard appCount > 0 else { return 0.05 }
        let withinApp: Double
        switch phase {
        case .comments: withinApp = 0.1
        case .images:
            let images = imagesTotal > 0 ? Double(imagesDone) / Double(imagesTotal) : 1
            withinApp = 0.25 + 0.55 * images
        case .crashes: withinApp = 0.85
        default: withinApp = 0
        }
        let value = (Double(appIndex) + withinApp) / Double(appCount)
        return min(0.97, 0.05 + value * 0.92)
    }
}
