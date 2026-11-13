import CMFMCore
import SwiftUI

struct CleanupView: View {
    @EnvironmentObject private var state: AppState
    @State private var expanded: Set<String> = []
    @State private var confirming = false

    /// Rows shown per category; the selection still covers every item.
    private static let visibleItems = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Nettoyage", subtitle: "Fichiers que tu peux supprimer sans rien casser.") {
                Button(state.isCleanScanning ? "Analyse…" : "Réanalyser") { state.scanCleanup() }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(state.isCleanScanning || state.isDeleting)
            }

            if state.isCleanScanning && state.cleanResults.isEmpty {
                EmptyState(symbol: "sparkles", title: "Analyse en cours…", message: "Mesure des caches et journaux.") {
                    ProgressView().controlSize(.small)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(state.cleanResults) { result in
                            categoryCard(result)
                        }
                    }
                }
                .scrollIndicators(.never)
                footer
            }
        }
        .confirmationDialog("Nettoyer \(Fmt.bytes(state.cleanSelectedTotal)) ?", isPresented: $confirming) {
            Button(state.permanentDelete ? "Supprimer définitivement" : "Mettre à la Corbeille", role: .destructive) {
                Task { await state.cleanSelected() }
            }
        } message: {
            Text(state.permanentDelete
                 ? "Suppression définitive : impossible à annuler."
                 : "Les éléments vont dans la Corbeille (sauf le contenu de la Corbeille, supprimé pour de bon).")
        }
    }

    private func categoryCard(_ result: CleanResult) -> some View {
        let paths = Set(result.items.map(\.path))
        let selectedCount = paths.intersection(state.cleanSelection).count
        let isOpen = expanded.contains(result.id)
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    CheckBox(isOn: !paths.isEmpty && selectedCount == paths.count) {
                        if selectedCount == paths.count { state.cleanSelection.subtract(paths) } else { state.cleanSelection.formUnion(paths) }
                    }
                    Image(systemName: result.category.symbol).font(.system(size: 17)).foregroundStyle(Theme.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.category.title).font(.system(size: 14, weight: .semibold))
                        Text(result.category.detail).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Text(result.items.isEmpty ? "Rien à nettoyer" : Fmt.bytes(result.total))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(result.items.isEmpty ? AnyShapeStyle(Theme.secondaryText) : AnyShapeStyle(.white))
                    if !result.items.isEmpty {
                        Button {
                            if isOpen { expanded.remove(result.id) } else { expanded.insert(result.id) }
                        } label: {
                            Image(systemName: isOpen ? "chevron.up" : "chevron.down").frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if isOpen {
                    Divider().overlay(.white.opacity(0.1))
                    ForEach(result.items.prefix(Self.visibleItems)) { item in
                        HStack(spacing: 10) {
                            CheckBox(isOn: state.cleanSelection.contains(item.path)) {
                                if state.cleanSelection.contains(item.path) { state.cleanSelection.remove(item.path) } else { state.cleanSelection.insert(item.path) }
                            }
                            Text(item.label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.bytes(item.size)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.secondaryText)
                        }
                        .padding(.leading, 30)
                        .contextMenu { Button("Afficher dans le Finder") { revealInFinder(item.path) } }
                    }
                    if result.items.count > Self.visibleItems {
                        Text("+ \(result.items.count - Self.visibleItems) autres éléments plus petits")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).padding(.leading, 30)
                    }
                }
            }
        }
    }

    private var footer: some View {
        Card(padding: 14) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sélection : \(Fmt.bytes(state.cleanSelectedTotal))").font(.system(size: 15, weight: .bold, design: .rounded))
                    if let outcome = state.lastOutcome {
                        Text(outcome).font(.system(size: 12)).foregroundStyle(Theme.mint)
                    }
                }
                Spacer()
                Toggle("Suppression définitive", isOn: $state.permanentDelete)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    .help("Désactivé : les éléments vont dans la Corbeille et restent récupérables.")
                if state.isDeleting { ProgressView().controlSize(.small) }
                Button("Nettoyer") { confirming = true }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(state.cleanSelection.isEmpty || state.isDeleting || state.isCleanScanning)
            }
        }
    }
}
