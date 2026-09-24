import AppKit
import SwiftData
import SwiftUI

struct FeedbackInspector: View {
    let feedback: Feedback?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if let feedback {
                inspector(feedback)
            } else {
                ContentUnavailableView("Selecciona un elemento", systemImage: "sidebar.right", description: Text("El detalle de comentarios y errores aparece aquí."))
            }
        }
        .frame(minWidth: 240)
    }

    private func inspector(_ item: Feedback) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !item.screenshotPaths.isEmpty {
                    ScreenshotGallery(paths: item.orderedScreenshotPaths)
                        .id(item.appleId)
                } else if item.kind == "Error" {
                    Label("Reporte de error", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(item.comment ?? "Reporte de error").font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(item.createdDate.formatted(date: .complete, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }

                GroupBox("Tester y dispositivo") {
                    VStack(alignment: .leading, spacing: 7) {
                        metadata("Tester", item.testerEmail)
                        metadata("Dispositivo", item.deviceModel.map { DeviceNames.labeled($0) })
                        metadata("Sistema", item.osVersion)
                        metadata("Build", item.buildNumber)
                        metadata("Versión", item.appVersion)
                        metadata("Idioma", item.locale)
                        metadata("Zona horaria", item.timeZone)
                        metadata("Conexión", item.connectionType)
                        metadata("Batería", item.batteryPercentage.map { "\($0)%" })
                        metadata("App", item.app?.name)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if item.kind == "Error", let path = item.crashLogPath {
                    GroupBox("Crash log") {
                        let log = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "No se pudo leer el log local."
                        ScrollView([.horizontal, .vertical]) {
                            Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }.frame(minHeight: 160, maxHeight: 260)
                        HStack {
                            Button("Copiar") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(log, forType: .string) }
                            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            Button("Abrir en Consola") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        }.padding(.top, 8)
                    }
                }

                GroupBox("Seguimiento") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Estado", selection: Binding(get: { item.status }, set: { item.status = $0; try? modelContext.save() })) {
                            ForEach(FeedbackStatus.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                        TextEditor(text: Binding(get: { item.notes }, set: { item.notes = $0; try? modelContext.save() }))
                            .frame(minHeight: 90).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    }
                }
            }
            .padding(16)
        }
    }

    private func metadata(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            return AnyView(HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary).frame(width: 95, alignment: .leading)
                Text(value).textSelection(.enabled)
            }.font(.caption))
        }
        return AnyView(EmptyView())
    }
}
