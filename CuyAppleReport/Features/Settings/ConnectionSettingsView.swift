import AppKit
import CryptoKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import Security
import ServiceManagement

struct ConnectionSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @Query(sort: \Connection.createdAt) private var connections: [Connection]
    @State private var name = ""
    @State private var issuerId = ""
    @State private var keyId = ""
    @State private var interval = 60
    @State private var pendingKey: Data?
    @State private var keyFileName: String?
    @State private var showImporter = false
    @State private var showRemoveConfirmation = false
    @State private var testing = false
    @State private var availableApps: [ASCApp] = []
    @State private var selectedAppIds = Set<String>()
    @State private var launchAtLogin = false
    @State private var message: String?
    @State private var isError = false
    @State private var authMode: AuthMode = .webSession
    @State private var draftId = UUID()
    @State private var session: ASCSessionInfo?
    @State private var selectedTeamId: Int?

    private var currentConnection: Connection? { connections.first }
    private var validIssuer: Bool { UUID(uuidString: issuerId.trimmingCharacters(in: .whitespacesAndNewlines)) != nil }
    private var validKeyId: Bool { keyId.range(of: "^[A-Za-z0-9]{10}$", options: .regularExpression) != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canTest: Bool {
        switch authMode {
        case .webSession: session != nil
        case .apiKey: validIssuer && validKeyId && (pendingKey != nil || currentConnection?.authMode == .apiKey)
        }
    }
    private var canSave: Bool {
        guard !trimmedName.isEmpty else { return false }
        return authMode == .webSession ? session != nil : validIssuer && validKeyId
    }

    var body: some View {
        TabView {
            connectionForm.tabItem { Label("Conexión", systemImage: "key.horizontal") }
            appsForm.tabItem { Label("Apps", systemImage: "square.stack.3d.up") }
            syncForm.tabItem { Label("Sincronización", systemImage: "arrow.triangle.2.circlepath") }
            generalForm.tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(20)
        .task {
            loadExisting()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.p8Key, .data]) { result in
            if case .success(let url) = result { loadKey(from: url) }
            if case .failure(let error) = result { setMessage(error.localizedDescription, error: true) }
        }
        .confirmationDialog("¿Eliminar la conexión?", isPresented: $showRemoveConfirmation, titleVisibility: .visible) {
            Button("Eliminar conexión y todos sus datos", role: .destructive) { removeConnection() }
        } message: {
            Text("Se eliminarán la clave de Keychain o la sesión de Apple, las apps y el feedback local asociado.")
        }
    }

    private var connectionForm: some View {
        Form {
            Section("Conexión") {
                LabeledContent {
                    TextField("Ej. CuyCoders — principal", text: $name, prompt: Text("Ej. CuyCoders — principal"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                } label: {
                    HStack(spacing: 6) {
                        Text("Nombre de la conexión")
                        HelpTipButton(
                            title: "Nombre de la conexión",
                            message: "Es una etiqueta local para reconocer esta cuenta en CuyAppleReport, por ejemplo “CuyCoders — principal”. No te la entrega Apple y no es una credencial."
                        )
                    }
                }
                Picker("Modo", selection: $authMode) {
                    ForEach(AuthMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: authMode) { message = nil }
                Text(authMode == .webSession
                     ? "Usa tu sesión de App Store Connect con tus mismos permisos. No necesitas API key."
                     : "Usa la API oficial con una API key de equipo creada por un Admin.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if authMode == .webSession {
                webSessionSection
            }

            if authMode == .apiKey {
                Section("Credenciales de App Store Connect") {
                    LabeledContent {
                        TextField("UUID de App Store Connect", text: $issuerId, prompt: Text("UUID de App Store Connect"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Issuer ID")
                            HelpTipButton(
                                title: "Issuer ID",
                                message: "Esta versión usa una Team API Key. En App Store Connect ve a Usuarios y acceso → Integraciones → App Store Connect API. Copia el Issuer ID que aparece sobre la lista de claves y pégalo completo aquí.",
                                linkTitle: "Abrir App Store Connect",
                                linkURL: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")
                            )
                        }
                    }
                    LabeledContent {
                        TextField("10 caracteres", text: $keyId, prompt: Text("10 caracteres"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Key ID")
                            HelpTipButton(
                                title: "Key ID",
                                message: "En la pestaña Team Keys de la misma página, copia el identificador de la clave que descargaste. Debe corresponder al archivo .p8. Si su nombre es AuthKey_<ID>.p8, CuyAppleReport completará este campo al cargarlo.",
                                linkTitle: "Abrir App Store Connect",
                                linkURL: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")
                            )
                        }
                    }
                    HStack {
                        Link("Abrir App Store Connect", destination: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!)
                        Spacer()
                        if !issuerId.isEmpty && !validIssuer { Label("Issuer ID no válido", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        if !keyId.isEmpty && !validKeyId { Label("El Key ID debe tener 10 caracteres", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                }

                Section {
                    keyDropZone
                    Text("La clave se guarda en Keychain al pulsar Guardar. Nunca se copia a archivos ni se muestra en pantalla.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    HStack(spacing: 6) {
                        Text("Clave privada")
                        HelpTipButton(
                            title: "Clave privada .p8",
                            message: "En App Store Connect API → Team Keys, genera una clave de equipo y descárgala. Apple permite descargar el .p8 una sola vez, así que guárdalo en un lugar seguro. Arrástralo aquí o pulsa Seleccionar…; la app valida el archivo y Probar conexión comprueba si corresponde al Key ID. Se guarda en Keychain al pulsar Guardar.",
                            linkTitle: "Guía oficial de claves",
                            linkURL: URL(string: "https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api")
                        )
                    }
                }
            }

            if let message {
                Text(message).foregroundStyle(isError ? .red : .green).textSelection(.enabled)
            }

            HStack {
                Button("Probar conexión") { Task { await testConnection() } }
                    .disabled(testing || !canTest)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Guardar") { saveConnection() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var webSessionSection: some View {
        Section {
            if let session {
                Label("Sesión iniciada como \(session.email ?? session.fullName ?? "usuario")", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if !session.teams.isEmpty {
                    Picker("Equipo", selection: $selectedTeamId) {
                        ForEach(session.teams) { team in Text(team.name).tag(Optional(team.id)) }
                    }
                    .onChange(of: selectedTeamId) { oldValue, newValue in
                        guard oldValue != nil, oldValue != newValue else { return }
                        availableApps = []
                        selectedAppIds = []
                        setMessage("Pulsa Probar conexión para cargar las apps de este equipo.", error: false)
                    }
                }
                HStack {
                    Button("Abrir App Store Connect…") { openLogin(autoClose: false) }
                    Spacer()
                    Button("Cerrar sesión", role: .destructive) { Task { await signOutSession() } }
                }
            } else {
                if currentConnection?.authMode == .webSession, currentConnection?.sessionState == .expired {
                    Label("La sesión expiró. Vuelve a iniciar sesión para seguir sincronizando.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button { openLogin(autoClose: true) } label: {
                        Label("Iniciar sesión con Apple", systemImage: "apple.logo")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Spacer()
                }
                .padding(.vertical, 6)
                Text("Se abrirá la página de App Store Connect. Tu contraseña y el código de verificación se escriben en la web de Apple; CuyAppleReport no los ve ni los guarda.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 6) {
                Text("Cuenta de Apple")
                HelpTipButton(
                    title: "Iniciar sesión con Apple ID",
                    message: "Usa tu sesión de App Store Connect con tus mismos permisos, sin API key; sirve para el rol Gestor de apps. La sesión caduca cada cierto tiempo (días o semanas) y habrá que volver a iniciarla. Este modo usa la API interna de la web de Apple, que puede cambiar sin aviso: si un Admin te habilita una API key, conviene pasarte a ese modo."
                )
            }
        }
    }

    private var keyDropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: pendingKey == nil && currentConnection?.authMode != .apiKey ? "key.fill" : "checkmark.seal.fill")
                .font(.system(size: 28)).foregroundStyle(pendingKey == nil && currentConnection?.authMode != .apiKey ? Color.gray : Color.green)
            Text(keyFileName.map { "✓ \($0) cargada" } ?? (currentConnection?.authMode != .apiKey ? "Arrastra aquí tu AuthKey_XXXX.p8" : "Clave guardada en Keychain"))
            HStack {
                Button("Seleccionar…") { showImporter = true }
                if pendingKey != nil { Button("Reemplazar") { showImporter = true } }
            }
        }
        .frame(maxWidth: .infinity).padding(22)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5])))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.pathExtension.lowercased() == "p8" else { return false }
            loadKey(from: url)
            return pendingKey != nil
        }
    }

    private var appsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Elige las apps cuyo feedback quieres sincronizar.").foregroundStyle(.secondary)
                Spacer()
                Button("Probar conexión") { Task { await testConnection() } }
                    .disabled(testing || !canTest)
            }
            if availableApps.isEmpty {
                ContentUnavailableView("Sin apps cargadas", systemImage: "square.stack.3d.up", description: Text("Prueba la conexión para cargar las apps de tu cuenta."))
            } else {
                List(availableApps) { app in
                    Toggle(isOn: Binding(get: { selectedAppIds.contains(app.id) }, set: { selected in
                        if selected { selectedAppIds.insert(app.id) } else { selectedAppIds.remove(app.id) }
                    })) {
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text(app.bundleId).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            if let message { Text(message).foregroundStyle(isError ? .red : .green) }
        }
        .padding(.top, 12)
    }

    private var syncForm: some View {
        Form {
            Section("Frecuencia automática") {
                Picker("Sincronizar cada", selection: $interval) {
                    Text("Manual").tag(0)
                    if authMode == .apiKey { Text("15 minutos").tag(15) }
                    Text("1 hora").tag(60)
                    Text("6 horas").tag(360)
                    Text("24 horas").tag(1440)
                }
                .pickerStyle(.menu)
                Text(authMode == .webSession
                     ? "La sincronización automática funciona mientras CuyAppleReport está abierta. Con sesión de Apple ID, el mínimo es cada 1 hora."
                     : "La sincronización automática funciona mientras CuyAppleReport está abierta.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Historial") {
                SyncHistoryView()
            }
        }
        .formStyle(.grouped)
    }

    private var generalForm: some View {
        Form {
            Section("Privacidad") {
                Label("La clave privada solo se guarda en Keychain.", systemImage: "lock.shield")
                Label("Con Apple ID, la contraseña solo se escribe en la página de Apple; la app guarda únicamente la sesión web.", systemImage: "person.badge.key")
                Label("El feedback se guarda localmente en este Mac.", systemImage: "internaldrive")
            }
            Section("Inicio") {
                Toggle("Abrir al iniciar sesión", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            setMessage("No se pudo cambiar el inicio de sesión: \(error.localizedDescription)", error: true)
                        }
                    }
                if let message { Text(message).foregroundStyle(isError ? .red : .green) }
            }
            if currentConnection != nil {
                Section {
                    Button("Eliminar conexión…", role: .destructive) { showRemoveConfirmation = true }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func loadExisting() {
        guard let connection = currentConnection else { return }
        authMode = connection.authMode
        draftId = connection.id
        selectedTeamId = connection.teamId
        if connection.authMode == .webSession, connection.accountEmail != nil, connection.sessionState != .expired {
            session = ASCSessionInfo(email: connection.accountEmail, fullName: connection.accountName,
                                     team: connection.teams.first { $0.id == connection.teamId }, teams: connection.teams)
        }
        name = connection.name
        issuerId = connection.issuerId
        keyId = connection.keyId
        interval = connection.syncIntervalMinutes
        selectedAppIds = Set(connection.apps.filter(\.isMonitored).map(\.appleId))
        availableApps = connection.apps.map { ASCApp(id: $0.appleId, name: $0.name, bundleId: $0.bundleId) }
    }

    private func loadKey(from url: URL) {
        guard url.pathExtension.lowercased() == "p8" else { setMessage("Selecciona un archivo con extensión .p8.", error: true); return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            _ = try P256.Signing.PrivateKey(pemRepresentation: String(decoding: data, as: UTF8.self))
            pendingKey = data
            keyFileName = url.lastPathComponent
            let stem = url.deletingPathExtension().lastPathComponent
            if stem.hasPrefix("AuthKey_") {
                let filenameKeyId = String(stem.dropFirst("AuthKey_".count))
                if filenameKeyId.range(of: "^[A-Za-z0-9]{10}$", options: .regularExpression) != nil { keyId = filenameKeyId }
            }
            setMessage("Clave privada válida. Se guardará al pulsar Guardar.", error: false)
        } catch {
            pendingKey = nil
            keyFileName = nil
            setMessage("El archivo no es una clave privada válida.", error: true)
        }
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            switch authMode {
            case .webSession:
                let transport = WebSessionTransport(connectionId: draftId)
                var info = try await transport.session()
                if let teamId = selectedTeamId, info.team?.id != teamId,
                   let team = info.teams.first(where: { $0.id == teamId }) {
                    info = try await transport.switchTeam(to: team)
                }
                session = info
                selectedTeamId = info.team?.id
                availableApps = try await AppStoreConnectClient(transport: transport).fetchApps()
            case .apiKey:
                guard validIssuer, validKeyId else { setMessage("Revisa el Issuer ID y el Key ID.", error: true); return }
                let pem = try pendingKey ?? KeychainStore.load(account: keyId)
                let provider = try AppleTokenProvider(issuerId: issuerId, keyId: keyId, pemData: pem)
                availableApps = try await AppStoreConnectClient(tokenProvider: provider).fetchApps()
            }
            if selectedAppIds.isEmpty { selectedAppIds = Set(availableApps.map(\.id)) }
            setMessage("Conexión exitosa · \(availableApps.count) apps encontradas.", error: false)
        } catch ASCError.sessionExpired {
            session = nil
            setMessage(ASCError.sessionExpired.localizedDescription, error: true)
        } catch {
            setMessage(error.localizedDescription, error: true)
        }
    }

    private func openLogin(autoClose: Bool) {
        AppleLoginWindow.present(connectionId: draftId, autoClose: autoClose) { info in
            session = info
            if !autoClose || selectedTeamId == nil || !info.teams.contains(where: { $0.id == selectedTeamId }) {
                selectedTeamId = info.team?.id
            }
            if trimmedName.isEmpty { name = info.team?.name ?? "Mi cuenta de Apple" }
            if let connection = currentConnection, connection.id == draftId, connection.authMode == .webSession {
                if !autoClose { connection.teamId = info.team?.id }
                connection.apply(info)
                try? modelContext.save()
            }
            setMessage("Sesión iniciada. Pulsa Probar conexión para cargar las apps.", error: false)
        }
    }

    private func signOutSession() async {
        await WebSessionStore.signOut(draftId)
        session = nil
        if let connection = currentConnection, connection.id == draftId, connection.authMode == .webSession {
            connection.accountEmail = nil
            connection.sessionState = .unknown
            try? modelContext.save()
        }
        setMessage("Sesión cerrada.", error: false)
    }

    private func saveConnection() {
        guard canSave else {
            setMessage(authMode == .webSession
                       ? "Completa el nombre e inicia sesión con tu Apple ID."
                       : "Completa el nombre y verifica Issuer ID y Key ID.", error: true)
            return
        }
        do {
            let previousKeyId = currentConnection?.authMode == .apiKey ? currentConnection?.keyId : nil
            if authMode == .apiKey {
                if let pendingKey { try KeychainStore.save(pendingKey, account: keyId) }
                else if previousKeyId == nil { throw KeychainError(status: errSecItemNotFound) }
            }
            let connection = currentConnection ?? Connection(id: draftId, name: trimmedName, issuerId: "", keyId: "", authMode: authMode)
            connection.name = trimmedName
            connection.authMode = authMode
            connection.syncIntervalMinutes = interval
            switch authMode {
            case .apiKey:
                connection.issuerId = issuerId
                connection.keyId = keyId
            case .webSession:
                connection.issuerId = ""
                connection.keyId = ""
                connection.teamId = selectedTeamId ?? session?.team?.id
                if let session { connection.apply(session) }
            }
            if currentConnection == nil { modelContext.insert(connection) }
            let oldApps = Dictionary(uniqueKeysWithValues: connection.apps.map { ($0.appleId, $0) })
            let appList = availableApps.isEmpty
                ? connection.apps.map { ASCApp(id: $0.appleId, name: $0.name, bundleId: $0.bundleId) }
                : availableApps
            for appInfo in appList {
                if let app = oldApps[appInfo.id] {
                    app.name = appInfo.name
                    app.bundleId = appInfo.bundleId
                    app.isMonitored = selectedAppIds.contains(appInfo.id)
                } else {
                    let app = MonitoredApp(appleId: appInfo.id, name: appInfo.name, bundleId: appInfo.bundleId,
                                           isMonitored: selectedAppIds.contains(appInfo.id), connection: connection)
                    connection.apps.append(app)
                }
            }
            try modelContext.save()
            if let previousKeyId, authMode != .apiKey || previousKeyId != keyId { KeychainStore.delete(account: previousKeyId) }
            pendingKey = nil
            keyFileName = nil
            appState.modelContext = modelContext
            appState.startAutoSync()
            setMessage("Conexión guardada.", error: false)
        } catch {
            setMessage(error.localizedDescription, error: true)
        }
    }

    private func removeConnection() {
        guard let connection = currentConnection else { return }
        if connection.authMode == .apiKey { KeychainStore.delete(account: connection.keyId) }
        let connectionId = connection.id
        Task { await WebSessionStore.signOut(connectionId) }
        let appIds = Set(connection.apps.map(\.appleId))
        let localPaths = connection.apps.flatMap(\.feedbacks).flatMap { $0.screenshotPaths + [$0.crashLogPath].compactMap { $0 } }
        FileStore.removeLocalFiles(at: localPaths)
        if let runs = try? modelContext.fetch(FetchDescriptor<SyncRun>()) {
            for run in runs where appIds.contains(run.appleAppId) { modelContext.delete(run) }
        }
        modelContext.delete(connection)
        try? modelContext.save()
        appState.startAutoSync()
        name = ""; issuerId = ""; keyId = ""; pendingKey = nil; keyFileName = nil
        session = nil; selectedTeamId = nil; draftId = UUID()
        availableApps = []; selectedAppIds = []
        setMessage("Conexión y datos locales eliminados.", error: false)
    }

    private func setMessage(_ value: String, error: Bool) {
        message = value
        isError = error
    }
}

private extension UTType {
    static let p8Key = UTType(importedAs: "com.apple.p8-private-key", conformingTo: .data)
}

private struct HelpTipButton: View {
    let title: String
    let message: String
    var linkTitle: String? = nil
    var linkURL: URL? = nil
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Cómo obtener \(title)")
        .accessibilityLabel("Ayuda: \(title)")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let linkURL {
                    Link(linkTitle ?? "Abrir guía de Apple", destination: linkURL)
                        .font(.callout.weight(.medium))
                }
            }
            .padding(16)
            .frame(width: 310, alignment: .leading)
        }
    }
}

private struct SyncHistoryView: View {
    @Query(sort: \SyncRun.startedAt, order: .reverse) private var runs: [SyncRun]
    var body: some View {
        if runs.isEmpty {
            Text("Todavía no hay sincronizaciones registradas.").foregroundStyle(.secondary)
        } else {
            Text(runs.prefix(20).map { run in
                "\(run.startedAt.formatted(date: .abbreviated, time: .shortened))  ·  \(run.errorMessage ?? "\(run.newItems) nuevos")"
            }.joined(separator: "\n"))
            .textSelection(.enabled)
        }
    }
}
