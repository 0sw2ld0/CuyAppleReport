import AppKit
import SwiftData
import SwiftUI

struct FeedbackListView: View {
    let items: [Feedback]
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @State private var layout: FeedbackLayout = .table
    @State private var selectedStatus = "Todos"
    @State private var selectedDevice = "Todos"
    @State private var selectedOS = "Todos"
    @State private var selectedTester = "Todos"
    @State private var selectedBuild = "Todos"
    @State private var selectedRange = "Todo el tiempo"

    private var filtered: [Feedback] {
        items.filter { item in
            (selectedStatus == "Todos" || item.status == selectedStatus) &&
            (selectedDevice == "Todos" || item.deviceModel == selectedDevice) &&
            (selectedOS == "Todos" || item.osVersion == selectedOS) &&
            (selectedTester == "Todos" || item.testerEmail == selectedTester) &&
            (selectedBuild == "Todos" || item.buildNumber == selectedBuild) &&
            (dateThreshold == nil || item.createdDate >= dateThreshold!)
        }
    }
    private var devices: [String] { Array(Set(items.compactMap(\.deviceModel))).sorted() }
    private var osVersions: [String] { Array(Set(items.compactMap(\.osVersion))).sorted() }
    private var testers: [String] { Array(Set(items.compactMap(\.testerEmail))).sorted() }
    private var builds: [String] { Array(Set(items.compactMap(\.buildNumber))).sorted() }
    private var dateThreshold: Date? {
        let days: Int? = switch selectedRange { case "7 días": 7; case "30 días": 30; case "90 días": 90; default: nil }
        return days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: .now) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
            HStack {
                Picker("Vista", selection: $layout) {
                    Image(systemName: "list.bullet").tag(FeedbackLayout.table)
                    Image(systemName: "square.grid.2x2").tag(FeedbackLayout.gallery)
                }.pickerStyle(.segmented).frame(width: 100)
                Picker("Estado", selection: $selectedStatus) {
                    Text("Todos los estados").tag("Todos")
                    ForEach(FeedbackStatus.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }.frame(width: 150)
                Picker("Dispositivo", selection: $selectedDevice) {
                    Text("Todos los dispositivos").tag("Todos")
                    ForEach(devices, id: \.self) { Text($0).tag($0) }
                }.frame(width: 190)
                Picker("SO", selection: $selectedOS) {
                    Text("Todas las versiones").tag("Todos")
                    ForEach(osVersions, id: \.self) { Text($0).tag($0) }
                }.frame(width: 150)
                Picker("Tester", selection: $selectedTester) {
                    Text("Todos los testers").tag("Todos")
                    ForEach(testers, id: \.self) { Text($0).tag($0) }
                }.frame(width: 200)
                Picker("Build", selection: $selectedBuild) {
                    Text("Todas las builds").tag("Todos")
                    ForEach(builds, id: \.self) { Text($0).tag($0) }
                }.frame(width: 160)
                Picker("Fecha", selection: $selectedRange) {
                    ForEach(["Todo el tiempo", "7 días", "30 días", "90 días"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 130)
                Text("\(filtered.count) elementos").font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            }

            if filtered.isEmpty {
                ContentUnavailableView(items.isEmpty ? "Sin feedback" : "Sin resultados", systemImage: "text.bubble", description: Text(items.isEmpty ? "Sincroniza App Store Connect para cargar feedback." : "Cambia o limpia los filtros para ver más elementos."))
            } else if layout == .table {
                tableView
            } else {
                galleryView
            }
        }
        .searchable(text: $appState.searchQuery, prompt: "Buscar comentario, tester o dispositivo")
    }

    private var tableView: some View {
        Table(filtered, selection: tableSelection) {
            TableColumn("Fecha") { feedback in
                Text(feedback.createdDate.formatted(date: .numeric, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }.width(min: 125, ideal: 145)
            TableColumn("Tester") { feedback in
                Text(feedback.testerEmail ?? "—").lineLimit(1)
            }.width(min: 125, ideal: 165)
            TableColumn("Comentario") { feedback in
                Text(feedback.comment ?? "Reporte de error").lineLimit(1)
            }.width(min: 160, ideal: 260)
            TableColumn("Capturas") { feedback in
                if feedback.screenshotPaths.isEmpty {
                    Text("—").foregroundStyle(.tertiary)
                } else {
                    Label("\(feedback.screenshotPaths.count)", systemImage: feedback.screenshotPaths.count > 1 ? "photo.stack" : "photo")
                        .foregroundStyle(.secondary)
                }
            }.width(min: 60, ideal: 75)
            TableColumn("Dispositivo") { feedback in Text(feedback.deviceModel ?? "—").lineLimit(1) }.width(min: 100, ideal: 130)
            TableColumn("iOS") { feedback in Text(feedback.osVersion ?? "—") }.width(min: 60, ideal: 75)
            TableColumn("Versión") { feedback in Text(feedback.appVersion ?? "—") }.width(min: 55, ideal: 70)
            TableColumn("Build") { feedback in Text(feedback.buildNumber ?? "—").lineLimit(1) }.width(min: 55, ideal: 110)
            TableColumn("Estado") { feedback in Text(feedback.status).foregroundStyle(statusColor(feedback.status)) }.width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { selection in
            Button("Marcar como en revisión") { updateStatus(selection, to: .inReview) }
            Button("Marcar como resuelto") { updateStatus(selection, to: .resolved) }
            Button("Copiar comentario") { copyComment(selection) }
        } primaryAction: { selection in
            if let id = selection.first, let feedback = filtered.first(where: { $0.persistentModelID == id }) {
                appState.selectedFeedbackId = feedback.appleId
            }
        }
    }

    /// La selección de la tabla se deriva de `appState.selectedFeedbackId` (una sola fuente de verdad):
    /// así, al cerrar el inspector o cambiar de sección, volver a pulsar la fila vuelve a abrir el detalle.
    private var tableSelection: Binding<Set<PersistentIdentifier>> {
        Binding(
            get: {
                guard let id = appState.selectedFeedbackId,
                      let item = filtered.first(where: { $0.appleId == id }) else { return [] }
                return [item.persistentModelID]
            },
            set: { selection in
                appState.selectedFeedbackId = filtered.first(where: { selection.contains($0.persistentModelID) })?.appleId
            }
        )
    }

    private var galleryView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(filtered) { feedback in
                    Button { appState.selectedFeedbackId = feedback.appleId } label: {
                        FeedbackCard(feedback: feedback)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ForEach(FeedbackStatus.allCases) { status in
                            Button(status.rawValue) { feedback.status = status.rawValue; try? modelContext.save() }
                        }
                        Button("Copiar comentario") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(feedback.comment ?? "", forType: .string) }
                    }
                }
            }.padding(16)
        }
    }

    private func updateStatus(_ selection: Set<PersistentIdentifier>, to status: FeedbackStatus) {
        for id in selection {
            if let item = filtered.first(where: { $0.persistentModelID == id }) { item.status = status.rawValue }
        }
        try? modelContext.save()
    }

    private func copyComment(_ selection: Set<PersistentIdentifier>) {
        guard let id = selection.first, let item = filtered.first(where: { $0.persistentModelID == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.comment ?? "", forType: .string)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case FeedbackStatus.resolved.rawValue: .green
        case FeedbackStatus.inReview.rawValue: .orange
        case FeedbackStatus.ignored.rawValue: .secondary
        default: .blue
        }
    }
}

private enum FeedbackLayout: Hashable { case table, gallery }

private struct FeedbackCard: View {
    let feedback: Feedback
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !feedback.screenshotPaths.isEmpty {
                ScreenshotCardPreview(paths: feedback.orderedScreenshotPaths)
            } else {
                RoundedRectangle(cornerRadius: 9).fill(.quaternary).frame(height: 100)
                    .overlay(Image(systemName: feedback.kind == "Error" ? "exclamationmark.triangle" : "text.bubble").font(.largeTitle).foregroundStyle(.secondary))
            }
            HStack {
                Text(feedback.app?.name ?? feedback.kind).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(feedback.status).font(.caption2).padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: Capsule())
            }
            Text(feedback.comment ?? "Crash report").font(.headline).lineLimit(3).foregroundStyle(.primary)
            HStack {
                Text(feedback.testerEmail ?? "Tester desconocido").lineLimit(1)
                Spacer()
                Text(feedback.createdDate.formatted(date: .abbreviated, time: .shortened))
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}
