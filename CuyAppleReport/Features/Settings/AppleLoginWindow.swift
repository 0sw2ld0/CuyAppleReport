import AppKit
import Security
import SwiftUI
import WebKit

/// Abre la web de App Store Connect en una ventana propia. El usuario inicia sesión (con 2FA)
/// en la página de Apple; la app nunca ve ni guarda la contraseña.
@MainActor
enum AppleLoginWindow {
    private static var window: NSWindow?
    private static var delegate: WindowDelegate?

    /// - Parameters:
    ///   - autoClose: cierra la ventana en cuanto detecta la sesión (login). Si es `false`
    ///     funciona como navegador de App Store Connect (por ejemplo, para cambiar de equipo).
    ///   - onSession: se llama cada vez que cambia la sesión detectada.
    static func present(connectionId: UUID, autoClose: Bool, onSession: @escaping @MainActor (ASCSessionInfo) -> Void) {
        window?.close()
        let start = URL(string: autoClose ? "https://appstoreconnect.apple.com/login" : "https://appstoreconnect.apple.com/apps")!
        let root = AppleLoginView(connectionId: connectionId, startURL: start, autoClose: autoClose,
                                  onSession: onSession, onClose: { AppleLoginWindow.window?.close() })
        let newWindow = NSWindow(contentViewController: NSHostingController(rootView: root))
        newWindow.title = autoClose ? "Iniciar sesión en App Store Connect" : "App Store Connect"
        newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        newWindow.setContentSize(NSSize(width: 1040, height: 760))
        newWindow.isReleasedWhenClosed = false
        let newDelegate = WindowDelegate()
        newWindow.delegate = newDelegate
        newWindow.center()
        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
        window = newWindow
        delegate = newDelegate
    }

    fileprivate static func didClose() {
        window = nil
        delegate = nil
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { AppleLoginWindow.didClose() }
        }
    }
}

private struct AppleLoginView: View {
    let connectionId: UUID
    let startURL: URL
    let autoClose: Bool
    let onSession: @MainActor (ASCSessionInfo) -> Void
    let onClose: @MainActor () -> Void
    @State private var detected: ASCSessionInfo?
    @State private var interception: Interception?
    @State private var showTrustConfirmation = false
    @State private var reloadToken = UUID()

    private enum Interception {
        case authority([SecCertificate])
        case withoutAuthority
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: detected == nil ? "lock.shield" : "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(detected == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    if let detected {
                        Text("Sesión iniciada como \(detected.email ?? detected.fullName ?? "usuario")").font(.headline)
                        Text("Equipo activo: \(detected.team?.name ?? "—")").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Inicia sesión con tu Apple ID").font(.headline)
                        Text("Tu contraseña y el código de verificación se escriben en la página de Apple. CuyAppleReport no los ve ni los guarda.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(detected == nil ? "Cancelar" : "Listo") { onClose() }
                    .keyboardShortcut(detected == nil ? .cancelAction : .defaultAction)
            }
            .padding(14)
            if let interception, detected == nil {
                interceptionBanner(interception)
            }
            Divider()
            AppleWebView(dataStore: WebSessionStore.dataStore(for: connectionId), startURL: startURL) { info in
                detected = info
                onSession(info)
                if autoClose {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(900))
                        onClose()
                    }
                }
            }
            .id(reloadToken)
        }
        .frame(minWidth: 820, minHeight: 600)
        .task { await detectInterception() }
        .alert("¿Confiar en el certificado de tu red?", isPresented: $showTrustConfirmation) {
            Button("Confiar y recargar") { trustDetectedAuthority() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            if case .authority(let certificates) = interception {
                Text(CorporateTrust.confirmationText(for: certificates))
            }
        }
    }

    /// Si la red intercepta las conexiones con Apple y aún no hay certificado, lo detecta y lo ofrece.
    private func detectInterception() async {
        guard !CorporateTrust.shared.isEnabled else { return }
        switch try? await CorporateTrust.detectInterception() {
        case .intercepted(let certificates): withAnimation { interception = .authority(certificates) }
        case .interceptedWithoutAuthority: withAnimation { interception = .withoutAuthority }
        default: break
        }
    }

    private func trustDetectedAuthority() {
        guard case .authority(let certificates) = interception else { return }
        CorporateTrust.shared.replace(with: certificates)
        withAnimation { interception = nil }
        reloadToken = UUID()
    }

    private func interceptionBanner(_ interception: Interception) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "building.2.crop.circle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tu red está inspeccionando las conexiones con Apple").font(.headline)
                switch interception {
                case .authority(let certificates):
                    Text("Por eso el formulario de inicio de sesión no carga. Certificado de la red: \(certificates.first.map { CorporateTrust.info($0).subject } ?? "desconocido").")
                        .font(.caption).foregroundStyle(.secondary)
                case .withoutAuthority:
                    Text("La red no envía su certificado raíz. Pídelo a TI e impórtalo en Ajustes → General → Red corporativa.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case .authority = interception {
                Button("Confiar en el certificado de la red…") { showTrustConfirmation = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct AppleWebView: NSViewRepresentable {
    let dataStore: WKWebsiteDataStore
    let startURL: URL
    let onSession: @MainActor (ASCSessionInfo) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSession: onSession) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: startURL))
        context.coordinator.start(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onSession = onSession
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onSession: @MainActor (ASCSessionInfo) -> Void
        private weak var webView: WKWebView?
        private var timer: Timer?
        private var lastReported: ASCSessionInfo?
        private var checking = false

        init(onSession: @escaping @MainActor (ASCSessionInfo) -> Void) {
            self.onSession = onSession
        }

        func start(_ webView: WKWebView) {
            self.webView = webView
            // La web de App Store Connect es una SPA: además de cada navegación, se revisa periódicamente.
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkSession() }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        /// Pregunta a `/olympus/v1/session` si ya hay sesión. Solo desde el dominio de App Store Connect.
        private func checkSession() {
            guard !checking, let webView, webView.url?.host == "appstoreconnect.apple.com" else { return }
            checking = true
            Task { @MainActor in
                defer { checking = false }
                let script = """
                const response = await fetch('/olympus/v1/session', { credentials: 'include', headers: { 'Accept': 'application/json' } });
                return { status: response.status, body: await response.text() };
                """
                guard let result = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any],
                      (result["status"] as? NSNumber)?.intValue == 200,
                      let body = result["body"] as? String,
                      let info = ASCSessionInfo(data: Data(body.utf8)),
                      info != lastReported else { return }
                lastReported = info
                onSession(info)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkSession()
        }

        /// Certificado corporativo opcional (inspección TLS). Sin certificado importado, delega en macOS.
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let (disposition, credential) = CorporateTrust.shared.disposition(for: challenge)
            completionHandler(disposition, credential)
        }

        /// Solo se navega dentro de dominios de Apple; cualquier otro enlace se abre en el navegador.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if Self.isAppleURL(url) || url.scheme == "about" {
                decisionHandler(.allow)
            } else {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
        }

        /// Enlaces con `target=_blank`: los de Apple se abren en la misma ventana.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if Self.isAppleURL(url) { webView.load(URLRequest(url: url)) } else { NSWorkspace.shared.open(url) }
            }
            return nil
        }

        private static func isAppleURL(_ url: URL) -> Bool {
            guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
            return host == "apple.com" || host.hasSuffix(".apple.com")
        }
    }
}
