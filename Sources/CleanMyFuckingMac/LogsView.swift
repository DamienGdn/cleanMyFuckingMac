import AppKit
import CMFMCore
import SwiftUI

struct LogsView: View {
    @State private var entries: [AppLog.Entry] = []
    @State private var minimumLevel: AppLog.Level = .info
    @State private var search = ""
    @State private var confirmingClear = false

    private static let timeFormat: Date.FormatStyle = .dateTime.hour().minute().second()

    private var visible: [AppLog.Entry] {
        let levels = AppLog.Level.allCases
        let threshold = levels.firstIndex(of: minimumLevel) ?? 0
        return entries.filter { entry in
            (levels.firstIndex(of: entry.level) ?? 0) >= threshold
                && (search.isEmpty || entry.message.localizedCaseInsensitiveContains(search)
                    || entry.category.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Journaux", subtitle: "Tout ce que l'app a fait.") {
                Picker("Niveau", selection: $minimumLevel) {
                    ForEach(AppLog.Level.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                TextField("Filtrer", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                Button("Copier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(visible.map(line).joined(separator: "\n"), forType: .string)
                }
                .buttonStyle(GhostButtonStyle())
                Button("Fichier dans le Finder") { revealInFinder(AppLog.shared.fileURL.path) }.buttonStyle(GhostButtonStyle())
                Button("Vider") { confirmingClear = true }.buttonStyle(GhostButtonStyle())
            }
            Card(padding: 10) {
                if visible.isEmpty {
                    Text("Aucune entrée.").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(visible) { entry in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(entry.date.formatted(Self.timeFormat)).foregroundStyle(Theme.secondaryText)
                                        Text(entry.level.rawValue).foregroundStyle(color(entry.level)).frame(width: 46, alignment: .leading)
                                        Text(entry.category).foregroundStyle(Theme.violet).frame(width: 92, alignment: .leading)
                                        Text(entry.message).textSelection(.enabled)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .id(entry.id)
                                }
                            }
                        }
                        .onChange(of: visible.last?.id) { _, last in
                            if let last { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
            Text("Fichier : \(AppLog.shared.fileURL.path) (rotation à 2 Mo)")
                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        }
        .onAppear { entries = AppLog.shared.snapshot() }
        .onReceive(NotificationCenter.default.publisher(for: AppLog.didChange).receive(on: RunLoop.main)) { _ in
            entries = AppLog.shared.snapshot()
        }
        .confirmationDialog("Vider les journaux ?", isPresented: $confirmingClear) {
            Button("Vider et supprimer les fichiers de log", role: .destructive) { AppLog.shared.clear() }
        }
    }

    private func line(_ entry: AppLog.Entry) -> String {
        "\(entry.date.formatted(.iso8601)) [\(entry.level.rawValue)] [\(entry.category)] \(entry.message)"
    }

    private func color(_ level: AppLog.Level) -> Color {
        switch level {
        case .debug: return Theme.secondaryText
        case .info: return Theme.mint
        case .warning: return Theme.orange
        case .error: return Theme.danger
        }
    }
}
