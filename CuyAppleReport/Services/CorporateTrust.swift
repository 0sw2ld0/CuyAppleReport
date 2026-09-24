import CryptoKit
import Foundation
import OSLog
import Security

/// Certificados raíz de una red corporativa que hace inspección TLS (opcional).
///
/// Si el usuario no importa ninguno, la app valida los certificados exactamente como macOS.
/// Si importa uno, se usa como raíz adicional **solo** para dominios de Apple y **solo**
/// cuando la validación normal falla. Nunca se aceptan certificados que no encadenen a él.
final class CorporateTrust: @unchecked Sendable {
    static let shared = CorporateTrust()

    struct CertificateInfo: Identifiable, Hashable, Sendable {
        /// Huella SHA-256 en hexadecimal.
        let id: String
        let subject: String

        var formattedFingerprint: String {
            stride(from: 0, to: id.count, by: 2).map { offset -> String in
                let start = id.index(id.startIndex, offsetBy: offset)
                return String(id[start..<id.index(start, offsetBy: 2)])
            }.joined(separator: ":")
        }
    }

    enum ImportError: LocalizedError {
        case noCertificates
        var errorDescription: String? {
            "El archivo no contiene certificados válidos. Usa un archivo .pem, .cer, .crt o .der."
        }
    }

    /// Sesión de red de la app: igual que `URLSession.shared`, pero respeta el certificado corporativo.
    static let urlSession: URLSession = URLSession(configuration: .default, delegate: TrustSessionDelegate(), delegateQueue: nil)

    private static let defaultsKey = "corporateTrustCertificates"
    private static let appleDomains = ["apple.com", "cdn-apple.com", "mzstatic.com"]
    private let logger = Logger(subsystem: "com.cuycoders.CuyAppleReport", category: "trust")
    private let lock = NSLock()
    private var anchors: [SecCertificate]

    private init() {
        let stored = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [Data] ?? []
        anchors = stored.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    var certificateInfos: [CertificateInfo] { snapshot().map(Self.info) }
    var isEnabled: Bool { !snapshot().isEmpty }

    // MARK: Importación

    /// Lee uno o varios certificados (PEM o DER) y descarta el del servidor si viene la cadena completa.
    static func certificates(from data: Data) throws -> [SecCertificate] {
        var certificates: [SecCertificate] = []
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            let blocks = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
            for block in blocks {
                guard let body = block.components(separatedBy: "-----END CERTIFICATE-----").first else { continue }
                let base64 = body.components(separatedBy: .whitespacesAndNewlines).joined()
                if let der = Data(base64Encoded: base64), let certificate = SecCertificateCreateWithData(nil, der as CFData) {
                    certificates.append(certificate)
                }
            }
        } else if let certificate = SecCertificateCreateWithData(nil, data as CFData) {
            certificates.append(certificate)
        }
        // En una cadena exportada con openssl el primero es el certificado del sitio (p. ej. idmsa.apple.com):
        // solo interesan las autoridades de la empresa.
        if certificates.count > 1 { certificates.removeFirst() }
        certificates.removeAll { (SecCertificateCopySubjectSummary($0) as String? ?? "").lowercased().contains("apple.com") }
        guard !certificates.isEmpty else { throw ImportError.noCertificates }
        return certificates
    }

    static func info(_ certificate: SecCertificate) -> CertificateInfo {
        let der = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
        return CertificateInfo(id: fingerprint, subject: SecCertificateCopySubjectSummary(certificate) as String? ?? "Certificado sin nombre")
    }

    func replace(with certificates: [SecCertificate]) {
        lock.withLock { anchors = certificates }
        UserDefaults.standard.set(certificates.map { SecCertificateCopyData($0) as Data }, forKey: Self.defaultsKey)
        logger.notice("Certificado corporativo activo: \(certificates.map { Self.info($0).subject }.joined(separator: ", "), privacy: .public)")
    }

    func removeAll() {
        lock.withLock { anchors = [] }
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        logger.notice("Certificado corporativo eliminado")
    }

    // MARK: Detección automática

    enum Detection {
        /// macOS confía en el certificado que presenta la red: no hay inspección TLS.
        case notIntercepted
        /// La red presenta otra autoridad: estos son sus certificados (sin el del sitio).
        case intercepted([SecCertificate])
        /// Hay inspección, pero la red no envió la autoridad; hay que importarla desde un archivo.
        case interceptedWithoutAuthority
    }

    /// Abre una conexión de prueba y la corta en cuanto recibe el certificado, antes de enviar datos.
    static func detectInterception(host: String = "idmsa.apple.com") async throws -> Detection {
        let capture = ChainCaptureDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: capture, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: "https://\(host)")!)
        } catch where capture.result != nil {
            // Esperado: cancelamos el desafío TLS a propósito.
        }
        guard let (chain, trusted) = capture.result else { throw URLError(.cannotConnectToHost) }
        if trusted { return .notIntercepted }
        var authorities = Array(chain.dropFirst())
        authorities.removeAll {
            let subject = (SecCertificateCopySubjectSummary($0) as String? ?? "").lowercased()
            return subject.contains("apple.com") || subject.hasPrefix("apple ")
        }
        return authorities.isEmpty ? .interceptedWithoutAuthority : .intercepted(authorities)
    }

    /// Texto de confirmación antes de confiar en un certificado.
    static func confirmationText(for certificates: [SecCertificate]) -> String {
        let list = certificates.map(info)
            .map { "\($0.subject)\nSHA-256 \($0.formattedFingerprint)" }
            .joined(separator: "\n\n")
        return list + "\n\nCuyAppleReport aceptará conexiones con dominios de Apple firmadas por este certificado, incluido el inicio de sesión del Apple ID, que macOS normalmente solo acepta con certificados de Apple. Tu empresa podrá ver ese tráfico, incluida tu contraseña al iniciar sesión, igual que ya ocurre en los navegadores de este Mac. Confía solo si reconoces el nombre del certificado y tu empresa lo permite."
    }

    // MARK: Validación

    enum Verdict: Equatable {
        /// macOS confía en el certificado: validación normal.
        case system
        /// No es de confianza para macOS, pero encadena al certificado corporativo (solo dominios de Apple).
        case corporate
        /// No es de confianza y no se acepta.
        case rejected
    }

    /// Respuesta a un desafío TLS. Sin certificado corporativo, siempre delega en macOS.
    func disposition(for challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard isEnabled,
              space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        switch evaluate(trust, host: space.host) {
        case .system: return (.performDefaultHandling, nil)
        case .corporate: return (.useCredential, URLCredential(trust: trust))
        case .rejected: return (.performDefaultHandling, nil)
        }
    }

    /// Decide si se acepta un certificado de servidor. Separado de `disposition` para poder probarlo.
    func evaluate(_ trust: SecTrust, host: String) -> Verdict {
        if SecTrustEvaluateWithError(trust, nil) { return .system }
        let anchors = snapshot()
        let root = Self.rootSummary(trust)
        guard !anchors.isEmpty else { return .rejected }
        guard Self.isAppleHost(host) else {
            logger.notice("TLS rechazado (no es un dominio de Apple): \(host, privacy: .public) · raíz \(root, privacy: .public)")
            return .rejected
        }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            logger.notice("TLS aceptado con el certificado corporativo: \(host, privacy: .public) · raíz \(root, privacy: .public)")
            return .corporate
        }
        // macOS aplica "pinning" a algunos dominios de Apple (p. ej. idmsa.apple.com, el login del Apple ID):
        // solo admite certificados emitidos por Apple aunque la raíz corporativa sea de confianza.
        // Igual que Chrome con raíces instaladas localmente, se valida la cadena sin esa regla, pero
        // exigiendo que termine exactamente en la raíz importada y que el nombre del servidor coincida.
        if Self.chainsToAnchorIgnoringPinning(trust, anchors: anchors, host: host) {
            logger.notice("TLS aceptado con el certificado corporativo (sin pinning de Apple): \(host, privacy: .public) · raíz \(root, privacy: .public)")
            return .corporate
        }
        logger.error("TLS rechazado: \(host, privacy: .public) no encadena al certificado corporativo · raíz \(root, privacy: .public) · \(error.map { String(describing: $0) } ?? "", privacy: .public)")
        return .rejected
    }

    /// Valida la cadena con la política TLS sin nombre de host (así macOS no aplica pinning), solo contra
    /// las raíces importadas, y comprueba aparte que el certificado del servidor sea para `host`.
    private static func chainsToAnchorIgnoringPinning(_ trust: SecTrust, anchors: [SecCertificate], host: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              dnsNames(leaf).contains(where: { hostMatches(host, pattern: $0) }) else { return false }
        var candidate: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, nil), &candidate) == errSecSuccess,
              let candidate else { return false }
        SecTrustSetAnchorCertificates(candidate, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(candidate, true)
        return SecTrustEvaluateWithError(candidate, nil)
    }

    private static func dnsNames(_ certificate: SecCertificate) -> [String] {
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDSubjectAltName] as CFArray, nil) as? [String: Any],
              let san = values[kSecOIDSubjectAltName as String] as? [String: Any],
              let entries = san[kSecPropertyKeyValue as String] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            (entry[kSecPropertyKeyLabel as String] as? String) == "DNS Name" ? entry[kSecPropertyKeyValue as String] as? String : nil
        }
    }

    /// Coincidencia de nombre de host (RFC 6125): exacta o comodín en la primera etiqueta (`*.apple.com`).
    static func hostMatches(_ host: String, pattern: String) -> Bool {
        let host = host.lowercased()
        let pattern = pattern.lowercased()
        if host == pattern { return true }
        guard pattern.hasPrefix("*.") else { return false }
        let suffix = String(pattern.dropFirst())
        guard host.hasSuffix(suffix) else { return false }
        let label = host.dropLast(suffix.count)
        return !label.isEmpty && !label.contains(".")
    }

    private func snapshot() -> [SecCertificate] {
        lock.withLock { anchors }
    }

    private static func isAppleHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return appleDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func rootSummary(_ trust: SecTrust) -> String {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let root = chain.last else { return "?" }
        return SecCertificateCopySubjectSummary(root) as String? ?? "?"
    }
}

/// Captura la cadena que presenta el servidor y cancela la conexión sin enviar datos.
private final class ChainCaptureDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: ([SecCertificate], Bool)?

    var result: ([SecCertificate], Bool)? { lock.withLock { captured } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            let trusted = SecTrustEvaluateWithError(trust, nil)
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
            lock.withLock { captured = (chain, trusted) }
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

private final class TrustSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = CorporateTrust.shared.disposition(for: challenge)
        completionHandler(disposition, credential)
    }
}
