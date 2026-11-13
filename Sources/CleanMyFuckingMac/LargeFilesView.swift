import CMFMCore
import SwiftUI

struct LargeFilesView: View {
    private enum Tab: String, CaseIterable { case large = "Gros et vieux fichiers", duplicates = "Doublons" }
    private enum Age: String, CaseIterable, Identifiable {
        case any = "Toutes dates", sixMonths = "Plus de 6 mois", oneYear = "Plus d'un an"
        var id: String { rawValue }
        var cutoff: Date? {
            switch self {
            case .any: return nil
            case .sixMonths: return Calendar.current.date(byAdding: .month, value: -6, to: .now)
            case .oneYear: return Calendar.current.date(byAdding: .year, value: -1, to: .now)
            }
        }
    }

    @EnvironmentObject private var state: AppState
    @State private var tab: Tab = .large
    @State private var minimumMB = 50
    @State private var age: Age = .any
    @State private var includeSystem = false
    @State private var selection: Set<String> = []
    @State private var confirming = false

    /// Rows rendered at once; filters narrow the list further.
    private static let visibleRows = 500

    private var filtered: [FileNode] {
        let minimum = Int64(minimumMB) << 20
        let cutoff = age.cutoff
        return state.largeFiles.filter { node in
            node.size >= minimum
                && (includeSystem || PathFilter.isUserContent(node.path, home: state.home))
                && (cutoff == nil || (node.modified ?? .now) < cutoff!)
        }
    }

    private var selectedNodes: [FileNode] {
        let pool = tab == .large ? state.largeFiles : (state.duplicateGroups ?? []).flatMap(\.files)
        return pool.filter { selection.contains($0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Gros fichiers", subtitle: "Les fichiers lourds, oubliés ou en double.") {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
            }

            if state.isScanning {
                Card { ScanProgressRow() }
                Spacer()
            } else if state.tree == nil {
                EmptyState(symbol: "doc.on.doc.fill", title: "Analyse nécessaire",
                           message: "Les gros fichiers et les doublons viennent de l'analyse du disque.") {
                    Button("Analyser mon dossier personnel") { state.startScan(root: state.home) }.buttonStyle(AccentButtonStyle())
                }
            } else {
                if tab == .large { largeList } else { duplicateList }
                footer
            }
        }
        .onChange(of: tab) { selection = [] }
        .confirmationDialog("Supprimer \(selectedNodes.count) fichier(s) ?", isPresented: $confirming) {
            Button(state.permanentDelete ? "Supprimer définitivement" : "Mettre à la Corbeille", role: .destructive) {
                let nodes = selectedNodes
                selection = []
                Task { await state.delete(nodes: nodes) }
            }
        } message: {
            Text("\(Fmt.bytes(selectedNodes.reduce(0) { $0 + $1.size })) au total.")
        }
    }

    private var largeList: some View {
        let files = filtered
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Picker("Taille", selection: $minimumMB) {
                    ForEach([50, 100, 500, 1024], id: \.self) { Text($0 >= 1024 ? "≥ 1 Go" : "≥ \($0) Mo").tag($0) }
                }
                .fixedSize()
                Picker("Âge", selection: $age) {
                    ForEach(Age.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Toggle("Inclure fichiers cachés et système", isOn: $includeSystem).font(.system(size: 12))
                Spacer()
                Text("\(files.count) fichiers · \(Fmt.bytes(files.reduce(0) { $0 + $1.size }))")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            Card(padding: 8) {
                if files.isEmpty {
                    Text("Aucun fichier ne correspond à ces filtres.").font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(files.prefix(Self.visibleRows)) { fileRow($0) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var duplicateList: some View {
        if state.isFindingDuplicates {
            EmptyState(symbol: "doc.on.doc.fill", title: "Comparaison des fichiers…",
                       message: "Calcul des empreintes des fichiers de même taille.") { ProgressView().controlSize(.small) }
        } else if let groups = state.duplicateGroups {
            if groups.isEmpty {
                EmptyState(symbol: "checkmark.seal.fill", title: "Aucun doublon",
                           message: "Aucun fichier identique de plus de 1 Mo dans tes documents.") { EmptyView() }
            } else {
                HStack {
                    Text("\(groups.count) groupes · \(Fmt.bytes(groups.reduce(0) { $0 + $1.wasted })) récupérables")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button("Tout sélectionner sauf un exemplaire") {
                        selection = Set(groups.flatMap { $0.files.dropFirst().map(\.path) })
                    }
                    .buttonStyle(GhostButtonStyle())
                }
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(groups.prefix(Self.visibleRows)) { group in
                            Card(padding: 8) {
                                VStack(spacing: 0) { ForEach(group.files) { fileRow($0) } }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        } else {
            EmptyState(symbol: "doc.on.doc.fill", title: "Chercher les doublons",
                       message: "Compare le contenu des fichiers de plus de 1 Mo de tes documents. Les dossiers cachés, la bibliothèque et l'intérieur des apps sont ignorés.") {
                Button("Chercher les doublons") { state.findDuplicates() }.buttonStyle(AccentButtonStyle())
            }
        }
    }

    private func fileRow(_ node: FileNode) -> some View {
        HStack(spacing: 10) {
            CheckBox(isOn: selection.contains(node.path)) {
                if selection.contains(node.path) { selection.remove(node.path) } else { selection.insert(node.path) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(node.path.replacingOccurrences(of: state.home, with: "~"))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if let modified = node.modified {
                Text(modified.shortLabel).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            Text(Fmt.bytes(node.size)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu { Button("Afficher dans le Finder") { revealInFinder(node.path) } }
    }

    private var footer: some View {
        Card(padding: 14) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sélection : \(Fmt.bytes(selectedNodes.reduce(0) { $0 + $1.size }))")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    if let outcome = state.lastOutcome {
                        Text(outcome).font(.system(size: 12)).foregroundStyle(Theme.mint)
                    }
                }
                Spacer()
                if state.isDeleting { ProgressView().controlSize(.small) }
                Button("Supprimer la sélection") { confirming = true }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(selection.isEmpty || state.isDeleting)
            }
        }
    }
}
