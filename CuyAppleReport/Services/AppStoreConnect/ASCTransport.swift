import Foundation

/// Cómo se autentica cada petición a App Store Connect. Las rutas y el JSON son los mismos
/// en la API oficial y en la API interna de la web (`/iris`), así que el cliente es común.
protocol ASCTransport: Sendable {
    /// `path` es relativo a la API y empieza con `/v1/…`.
    func get(_ path: String) async throws -> Data
}

extension ASCTransport {
    /// Convierte el `links.next` absoluto que devuelve Apple en una ruta `/v1/…`.
    /// Solo acepta hosts de App Store Connect.
    func relativePath(fromNextLink link: String) -> String? {
        guard let components = URLComponents(string: link),
              components.scheme == "https",
              ["api.appstoreconnect.apple.com", "appstoreconnect.apple.com"].contains(components.host ?? "")
        else { return nil }
        var path = components.percentEncodedPath
        if path.hasPrefix("/iris/") { path.removeFirst("/iris".count) }
        guard path.hasPrefix("/v1/") else { return nil }
        if let query = components.percentEncodedQuery { path += "?" + query }
        return path
    }
}

enum ASCHTTP {
    /// Devuelve los datos si el código es 2xx; si no, el error correspondiente.
    static func check(status: Int, data: Data, sessionMode: Bool) throws -> Data {
        if (200..<300).contains(status) { return data }
        if status == 401, sessionMode { throw ASCError.sessionExpired }
        let detail: String?
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = payload["errors"] as? [[String: Any]] {
            detail = errors.first?["detail"] as? String
        } else { detail = nil }
        throw ASCError.http(status, detail)
    }

    static func shouldRetry(_ status: Int) -> Bool { status == 429 || status == 503 }

    static func backoff(attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
    }
}

/// Modo API key: `https://api.appstoreconnect.apple.com` con JWT ES256.
struct APIKeyTransport: ASCTransport {
    let tokenProvider: AppleTokenProvider
    var session: URLSession = .shared
    private let baseURL = URL(string: "https://api.appstoreconnect.apple.com")!

    init(tokenProvider: AppleTokenProvider, session: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.session = session
    }

    func get(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw ASCError.invalidResponse }
        var lastError: Error = ASCError.network
        for attempt in 0..<5 {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(try tokenProvider.makeToken())", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ASCError.invalidResponse }
                if ASCHTTP.shouldRetry(http.statusCode), attempt < 4 {
                    try await ASCHTTP.backoff(attempt: attempt)
                    continue
                }
                return try ASCHTTP.check(status: http.statusCode, data: data, sessionMode: false)
            } catch let error as ASCError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 4 { try await ASCHTTP.backoff(attempt: attempt) }
            }
        }
        if let ascError = lastError as? ASCError { throw ascError }
        throw ASCError.network
    }
}
