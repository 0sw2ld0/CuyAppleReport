import Foundation

/// Nombres comerciales de los modelos de iPhone (`iPhone14_2` / `iPhone14,2` → "iPhone 13 Pro").
/// Los identificadores que no están en la tabla se muestran tal cual.
enum DeviceNames {
    private static let names: [String: String] = [
        "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2.ª gen.)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3.ª gen.)", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air"
    ]

    /// Nombre comercial, o el identificador tal cual si no se conoce.
    static func marketingName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Dispositivo desconocido" }
        return names[raw.replacingOccurrences(of: "_", with: ",")] ?? raw
    }

    /// "iPhone 13 Pro (iPhone14_2)"; solo el identificador si no se conoce.
    static func labeled(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Dispositivo desconocido" }
        let name = marketingName(raw)
        return name == raw ? raw : "\(name) (\(raw))"
    }
}

extension Feedback {
    /// Nombre comercial del dispositivo (p. ej. "iPhone 13 Pro").
    var deviceName: String { DeviceNames.marketingName(deviceModel) }
}
