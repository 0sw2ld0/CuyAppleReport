import Security
import SwiftUI
import UniformTypeIdentifiers

/// Ajustes → General: certificado de una red corporativa con inspección TLS (opcional).
struct CorporateCertificateSection: View {
    @State private var installed = CorporateTrust.shared.certificateInfos
    @State private var pending: [SecCertificate] = []
    @State private var showConfirmation = false
    @State private var showImporter = false
    @State private var targeted = false
    @State private var message: String?
    @State private var isError = false
    @State private var detecting = false

    private static let allowedTypes: [UTType] = [
        .x509Certificate,
        UTType(filenameExtension: "pem"),
        UTType(filenameExtension: "crt"),
        UTType(filenameExtension: "cer"),
        UTType(filenameExtension: "der"),
        .data
    ].compactMap { $0 }

    var body: some View {
        Section {
            Text("Úsalo solo si tu red (por ejemplo, la del trabajo) inspecciona las conexiones seguras y la ventana de inicio de sesión de Apple no carga. Si no importas ninguno, la app valida los certificados igual que macOS.")
                .font(.caption).foregroundStyle(.secondary)

            if installed.isEmpty {
                dropZone
            } else {
                ForEach(installed) { certificate in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(certificate.subject, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("SHA-256 \(certificate.formattedFingerprint)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Text("Se usa solo para dominios de Apple y solo cuando la validación normal de macOS falla.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Detectar de nuevo") { Task { await detect() } }.disabled(detecting)
                    Button("Reemplazar…") { showImporter = true }
                    Spacer()
                    Button("Quitar certificado", role: .destructive) {
                        CorporateTrust.shared.removeAll()
                        installed = []
                        setMessage("Certificado eliminado. La app vuelve a validar como macOS.", error: false)
                    }
                }
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(isError ? .red : .green)
            }
        } header: {
            Text("Red corporativa (opcional)")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.allowedTypes) { result in
            switch result {
            case .success(let url): load(url)
            case .failure(let error): setMessage(error.localizedDescription, error: true)
            }
        }
        .alert("¿Confiar en este certificado?", isPresented: $showConfirmation) {
            Button("Confiar para conexiones con Apple") { activate() }
            Button("Cancelar", role: .cancel) { pending = [] }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "building.2.crop.circle")
                .font(.system(size: 28))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            Button {
                Task { await detect() }
            } label: {
                if detecting {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Detectando…") }
                } else {
                    Label("Detectar automáticamente", systemImage: "wand.and.stars")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(detecting)
            Text("o arrastra aquí el certificado de tu empresa (.pem, .cer, .crt, .der)")
                .font(.caption).foregroundStyle(.secondary)
            Button("Seleccionar archivo…") { showImporter = true }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(targeted ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5])))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            load(url)
            return true
        } isTargeted: { targeted = $0 }
    }

    private var confirmationMessage: String {
        CorporateTrust.confirmationText(for: pending)
    }

    /// Conecta con Apple, lee el certificado que presenta la red y, si hay inspección, propone confiar.
    private func detect() async {
        detecting = true
        defer { detecting = false }
        do {
            switch try await CorporateTrust.detectInterception() {
            case .notIntercepted:
                setMessage("Tu red no intercepta las conexiones con Apple: no necesitas un certificado.", error: false)
            case .intercepted(let certificates):
                pending = certificates
                message = nil
                showConfirmation = true
            case .interceptedWithoutAuthority:
                setMessage("Tu red intercepta las conexiones con Apple, pero no envía su certificado raíz. Pídelo a TI e impórtalo como archivo.", error: true)
            }
        } catch {
            setMessage("No se pudo conectar con Apple para detectar el certificado: \(error.localizedDescription)", error: true)
        }
    }

    private func load(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            pending = try CorporateTrust.certificates(from: Data(contentsOf: url))
            message = nil
            showConfirmation = true
        } catch {
            setMessage(error.localizedDescription, error: true)
        }
    }

    private func activate() {
        CorporateTrust.shared.replace(with: pending)
        installed = CorporateTrust.shared.certificateInfos
        pending = []
        setMessage("Certificado activo. Vuelve a abrir la ventana de inicio de sesión de Apple.", error: false)
    }

    private func setMessage(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}
