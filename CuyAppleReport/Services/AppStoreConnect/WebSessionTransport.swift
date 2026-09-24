import Foundation
import WebKit

/// Datos de `GET /olympus/v1/session`.
struct ASCSessionInfo: Sendable, Equatable {
    let email: String?
    let fullName: String?
    let team: TeamInfo?
    let teams: [TeamInfo]
    let roles: [String]

    init(email: String?, fullName: String?, team: TeamInfo?, teams: [TeamInfo], roles: [String] = []) {
        self.email = email
        self.fullName = fullName
        self.team = team
        self.teams = teams
        self.roles = roles
    }

    /// Devuelve nil si la respuesta no trae un usuario (sesión no iniciada).
    init?(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = root["user"] as? [String: Any] else { return nil }
        email = user["emailAddress"] as? String
        fullName = user["fullName"] as? String
        team = (root["provider"] as? [String: Any]).flatMap(Self.team(from:))
        teams = (root["availableProviders"] as? [[String: Any]] ?? []).compactMap(Self.team(from:))
        roles = root["roles"] as? [String] ?? []
    }

    private static func team(from json: [String: Any]) -> TeamInfo? {
        guard let id = (json["providerId"] as? NSNumber)?.intValue else { return nil }
        return TeamInfo(id: id, publicId: json["publicProviderId"] as? String,
                        name: json["name"] as? String ?? "Equipo \(id)", subType: json["subType"] as? String)
    }
}

/// Almacén de sesión aislado por conexión: persiste entre reinicios y no se mezcla con Safari.
@MainActor
enum WebSessionStore {
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    static func dataStore(for connectionId: UUID) -> WKWebsiteDataStore {
        if let store = stores[connectionId] { return store }
        let store = WKWebsiteDataStore(forIdentifier: connectionId)
        stores[connectionId] = store
        return store
    }

    /// Cierra la sesión borrando cookies y datos web de esa conexión.
    static func signOut(_ connectionId: UUID) async {
        let store = dataStore(for: connectionId)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
    }
}

/// Modo sesión: ejecuta las peticiones dentro de un `WKWebView` oculto que comparte la sesión
/// de App Store Connect del usuario, igual que la propia web (`/iris/v1/…`).
final class WebSessionTransport: ASCTransport, @unchecked Sendable {
    static let origin = URL(string: "https://appstoreconnect.apple.com/olympus/v1/session")!

    private let connectionId: UUID
    @MainActor private var webView: WKWebView?
    @MainActor private var loader: PageLoader?

    init(connectionId: UUID) {
        self.connectionId = connectionId
    }

    func get(_ path: String) async throws -> Data {
        for attempt in 0..<5 {
            let (status, data) = try await request(method: "GET", path: "/iris" + path, body: nil)
            if ASCHTTP.shouldRetry(status), attempt < 4 {
                try await ASCHTTP.backoff(attempt: attempt)
                continue
            }
            return try ASCHTTP.check(status: status, data: data, sessionMode: true)
        }
        throw ASCError.network
    }

    /// Lee la sesión actual. Lanza `.sessionExpired` si no hay sesión iniciada.
    func session() async throws -> ASCSessionInfo {
        let (status, data) = try await request(method: "GET", path: "/olympus/v1/session", body: nil)
        let body = try ASCHTTP.check(status: status, data: data, sessionMode: true)
        guard let info = ASCSessionInfo(data: body) else { throw ASCError.sessionExpired }
        return info
    }

    /// Cambia el equipo activo de la sesión con la misma llamada que usa la web.
    func switchTeam(to team: TeamInfo) async throws -> ASCSessionInfo {
        let current = try await session()
        if current.team?.id == team.id { return current }
        for id in [String(team.id), team.publicId].compactMap({ $0 }) {
            let body = #"{"data":{"type":"providerSwitchRequests","relationships":{"provider":{"data":{"type":"providers","id":"\#(id)"}}}}}"#
            _ = try? await request(method: "POST", path: "/olympus/v1/providerSwitchRequests", body: body)
            let updated = try await session()
            if updated.team?.id == team.id { return updated }
        }
        throw ASCError.teamSwitchFailed(team.name)
    }

    @MainActor
    private func request(method: String, path: String, body: String?) async throws -> (Int, Data) {
        let webView = try await preparedWebView()
        let script = """
        const init = { method: method, credentials: 'include', headers: { 'Accept': 'application/json' } };
        if (body !== null) { init.body = body; init.headers['Content-Type'] = 'application/json'; }
        const response = await fetch(path, init);
        return { status: response.status, body: await response.text() };
        """
        let arguments: [String: Any] = ["method": method, "path": path, "body": body ?? NSNull()]
        let result = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient)
        guard let dictionary = result as? [String: Any] else { throw ASCError.invalidResponse }
        let status = (dictionary["status"] as? NSNumber)?.intValue ?? 0
        let text = dictionary["body"] as? String ?? ""
        return (status, Data(text.utf8))
    }

    @MainActor
    private func preparedWebView() async throws -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebSessionStore.dataStore(for: connectionId)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
        let loader = PageLoader()
        webView.navigationDelegate = loader
        try await loader.load(Self.origin, in: webView)
        self.webView = webView
        self.loader = loader
        return webView
    }
}

/// Espera a que termine la carga de la página base (mismo origen que la API interna).
@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ url: URL, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: ASCError.network)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: ASCError.network)
        continuation = nil
    }
}
