import SwiftUI

extension Feedback {
    /// Versión de la app para filtrar; los elementos sin versión se agrupan como "Sin versión".
    var versionKey: String { appVersion ?? VersionOptions.withoutVersion }
}

enum VersionOptions {
    static let withoutVersion = "Sin versión"

    struct Option: Identifiable, Hashable {
        let version: String
        let count: Int
        /// Texto que se muestra; por defecto "v1.2" o "Sin versión".
        var title: String
        var id: String { version }

        init(version: String, count: Int, title: String? = nil) {
            self.version = version
            self.count = count
            self.title = title ?? (version == VersionOptions.withoutVersion ? version : "v\(version)")
        }
    }

    /// Versiones presentes con su cantidad, de la más reciente a la más antigua ("Sin versión" al final).
    static func options(for items: [Feedback]) -> [Option] {
        var counts: [String: Int] = [:]
        for item in items { counts[item.versionKey, default: 0] += 1 }
        return counts.map { Option(version: $0.key, count: $0.value) }.sorted { lhs, rhs in
            if lhs.version == withoutVersion { return false }
            if rhs.version == withoutVersion { return true }
            return lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending
        }
    }
}

/// Lista de casillas para elegir varias versiones.
struct VersionChecklist: View {
    let options: [VersionOptions.Option]
    @Binding var selection: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Todas") { selection = Set(options.map(\.version)) }
                    .disabled(selection.count == options.count)
                Button("Ninguna") { selection = [] }
                    .disabled(selection.isEmpty)
            }
            .controlSize(.small)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options) { option in
                        Toggle(isOn: Binding(
                            get: { selection.contains(option.version) },
                            set: { isOn in
                                if isOn { selection.insert(option.version) } else { selection.remove(option.version) }
                            }
                        )) {
                            HStack {
                                Text(option.title)
                                Spacer()
                                Text("\(option.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
    }

    private var summary: String {
        switch selection.count {
        case options.count: "Todas las versiones"
        case 0: "Ninguna versión"
        case 1: "1 versión"
        default: "\(selection.count) versiones"
        }
    }
}

/// Botón del filtro de versiones: abre la lista de casillas. `nil` significa "todas".
struct VersionFilterButton: View {
    let options: [VersionOptions.Option]
    @Binding var selection: Set<String>?
    @State private var showPopover = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            HStack(spacing: 4) {
                Text(label).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .frame(minWidth: 120, alignment: .leading)
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VersionChecklist(options: options, selection: checklistSelection)
                .padding(14)
                .frame(width: 260)
        }
    }

    private var allVersions: Set<String> { Set(options.map(\.version)) }

    private var checklistSelection: Binding<Set<String>> {
        Binding(
            get: { selection ?? allVersions },
            set: { newValue in selection = newValue == allVersions ? nil : newValue }
        )
    }

    private var label: String {
        guard let selection else { return "Todas las versiones" }
        let active = selection.intersection(allVersions)
        switch active.count {
        case 0: return "Ninguna versión"
        case 1: return active.first.flatMap { version in options.first { $0.version == version }?.title } ?? ""
        default: return "\(active.count) versiones"
        }
    }
}
