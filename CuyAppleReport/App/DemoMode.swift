#if DEBUG
import AppKit
import SwiftData
import SwiftUI

/// Modo demo solo para compilaciones Debug (`--sync-demo`): base de datos en memoria,
/// feedback de ejemplo con varias capturas y una sincronización simulada. No toca datos reales.
enum DemoMode {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--sync-demo") }

    @MainActor
    static func seed(_ context: ModelContext) {
        let connection = Connection(name: "Demo", issuerId: "", keyId: "", authMode: .webSession)
        connection.accountEmail = "demo@example.com"
        connection.sessionState = .valid
        context.insert(connection)
        let app = MonitoredApp(appleId: "demo-app", name: "CuyBugs", bundleId: "com.example.cuybugs", connection: connection)
        connection.apps.append(app)
        let comments = ["El botón de pagar no responde en la pantalla de checkout",
                        "Los textos se cortan en modo oscuro",
                        "La lista tarda mucho en cargar"]
        for (index, comment) in comments.enumerated() {
            let paths = (0..<(3 - index)).compactMap { makeScreenshot(id: "demo-\(index)", index: $0) }
            let feedback = Feedback(appleId: "demo-\(index)", kind: "Comentario", comment: comment,
                                    testerEmail: "tester\(index)@example.com", deviceModel: "iPhone16_2",
                                    osVersion: "26.\(index)", appVersion: "1.0", buildNumber: "6\(index)",
                                    createdDate: .now.addingTimeInterval(Double(-index) * 3600),
                                    screenshotPaths: paths, app: app)
            context.insert(feedback)
        }
        let textOnly = ["Me encanta el nuevo diseño del inicio, se siente mucho más rápido y claro. Sería genial poder personalizar los accesos directos y ordenar las tarjetas según lo que más uso cada día.",
                        "No encuentro dónde cambiar mi contraseña",
                        "Al volver de segundo plano la app pide iniciar sesión otra vez aunque activé la opción de recordar mi usuario, y eso pasa varias veces al día. Además el teclado tapa el botón de continuar en pantallas pequeñas como el iPhone SE.",
                        "Todo bien 👍"]
        for (index, comment) in textOnly.enumerated() {
            context.insert(Feedback(appleId: "demo-text-\(index)", kind: "Comentario", comment: comment,
                                    testerEmail: "text\(index)@example.com", deviceModel: "iPhone17_1",
                                    osVersion: "26.1", appVersion: "1.1", buildNumber: "65",
                                    createdDate: .now.addingTimeInterval(Double(-index - 4) * 5400), app: app))
        }
        let crashTypes = ["EXC_CRASH (SIGABRT)", "EXC_BAD_ACCESS (SIGSEGV)", "EXC_BREAKPOINT (SIGTRAP)"]
        let reasons = ["SIGNAL 6 Abort trap: 6", "SIGNAL 11 Segmentation fault: 11", "SIGNAL 5 Trace/BPT trap: 5"]
        for index in 0..<5 {
            let log = """
            Incident Identifier: DEMO
            Hardware Model: iPhone17,3
            Process: CuyBugs [1234]
            Exception Type:  \(crashTypes[index % 3])
            Exception Subtype: KERN_INVALID_ADDRESS at 0x0000000000000010
            Termination Reason: \(reasons[index % 3])
            Triggered by Thread:  0

            Thread 0 Crashed:
            0   libsystem_kernel.dylib        \t0x00000001e1c2a1d4 __pthread_kill + 8
            1   libsystem_pthread.dylib       \t0x00000001f3a1b2c8 pthread_kill + 268
            2   libsystem_c.dylib             \t0x00000001a9b8c3d4 abort + 180
            3   libc++abi.dylib               \t0x00000001f39e4e8c abort_message + 132
            4   CuyBugs                       \t0x0000000100a1b2c4 CheckoutViewModel.pay() + 212 (CheckoutViewModel.swift:88)
            5   CuyBugs                       \t0x0000000100a1c3d8 closure #1 in CheckoutView.body.getter + 64 (CheckoutView.swift:42)
            6   SwiftUI                       \t0x00000001a2b3c4d5 0x1a2b00000 + 123456

            Binary Images:
            """
            let url = FileManager.default.temporaryDirectory.appending(path: "demo-crash-\(index).txt")
            try? Data(log.utf8).write(to: url)
            let crash = Feedback(appleId: "demo-crash-\(index)", kind: "Error", comment: index.isMultiple(of: 2) ? "Se cerró al abrir el perfil" : nil,
                                 testerEmail: "tester\(index)@example.com", deviceModel: index.isMultiple(of: 2) ? "iPhone17_3" : "iPhone18_2",
                                 osVersion: "26.\(index)", appVersion: "1.\(index)", buildNumber: "7\(index)",
                                 createdDate: .now.addingTimeInterval(Double(-index) * 86_400), crashLogPath: url.path, app: app)
            context.insert(crash)
        }
        try? context.save()
        if ProcessInfo.processInfo.arguments.contains("--export-pdf") {
            let all = (try? context.fetch(FetchDescriptor<Feedback>())) ?? []
            let url = FileManager.default.temporaryDirectory.appending(path: "demo-report.pdf")
            if let data = try? ExportService.data(for: .pdf, feedback: all, anonymizeEmails: false) {
                try? data.write(to: url)
                print("PDF_WRITTEN \(url.path) \(data.count)")
            }
            exit(0)
        }
    }

    @MainActor
    static func runFakeSync(_ appState: AppState) async {
        var progress = SyncProgress()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { appState.syncProgress = progress }
        appState.isSyncing = true
        try? await Task.sleep(for: .seconds(1.2))
        progress.appCount = 2
        for appIndex in 0..<2 {
            progress.appIndex = appIndex
            progress.appName = appIndex == 0 ? "CuyBugs" : "CuyCards"
            progress.imagesDone = 0
            progress.imagesTotal = 8
            progress.phase = .comments
            withAnimation(.snappy) { appState.syncProgress = progress }
            try? await Task.sleep(for: .seconds(1))
            progress.found += 6
            progress.phase = .images
            for _ in 0..<8 {
                progress.imagesDone += 1
                withAnimation(.snappy) { appState.syncProgress = progress }
                try? await Task.sleep(for: .milliseconds(350))
            }
            progress.newItems += 2
            progress.phase = .crashes
            withAnimation(.snappy) { appState.syncProgress = progress }
            try? await Task.sleep(for: .seconds(1))
        }
        progress.phase = .done
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appState.syncProgress = progress }
        appState.isSyncing = false
    }

    private static func makeScreenshot(id: String, index: Int) -> String? {
        let size = NSSize(width: 590, height: 1280)
        let image = NSImage(size: size, flipped: false) { rect in
            let hues: [CGFloat] = [0.58, 0.78, 0.08]
            NSGradient(colors: [NSColor(hue: hues[index % 3], saturation: 0.6, brightness: 0.9, alpha: 1),
                                NSColor(hue: hues[index % 3], saturation: 0.8, brightness: 0.45, alpha: 1)])?
                .draw(in: rect, angle: -90)
            let text = "Captura \(index + 1)" as NSString
            text.draw(at: NSPoint(x: 150, y: 620), withAttributes: [
                .font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.white
            ])
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "demo-\(id)-\(index).png")
        try? png.write(to: url)
        return url.path
    }
}
#endif
