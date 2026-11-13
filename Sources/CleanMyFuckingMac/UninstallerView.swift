import AppKit
import CMFMCore
import SwiftUI

struct UninstallerView: View {
    @EnvironmentObject private var state: AppState
    @State private var search = ""
    @State private var selected: InstalledApp?
    @State private var leftovers: [CleanItem] = []
    @State private var isLoadingLeftovers = false
    @State private var confirming = false

    private var visibleApps: [InstalledApp] {
        search.isEmpty ? state.apps : state.apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var isRunning: Bool {
        guard let selected else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: selected.bundleID).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Désinstalleur", subtitle: "Supprime une app et tout ce qu'elle a laissé derrière elle.") {
                TextField("Rechercher", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Actualiser") { state.loadApps() }.buttonStyle(GhostButtonStyle()).disabled(state.isLoadingApps)
            }

            if state.isLoadingApps && state.apps.isEmpty {
                EmptyState(symbol: "xmark.app.fill", title: "Inventaire des applications…", message: "Mesure de la taille de chaque app.") {
                    ProgressView().controlSize(.small)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    Card(padding: 8) {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(visibleApps) { appRow($0) }
                            }
                        }
                    }
                    detail.frame(width: 420)
                }
            }
        }
        .confirmationDialog("Désinstaller \(selected?.name ?? "") ?", isPresented: $confirming, presenting: selected) { app in
            Button("Mettre l'app et ses données à la Corbeille", role: .destructive) {
                let items = leftovers
                selected = nil
                Task { await state.uninstall(app, leftovers: items) }
            }
        } message: { app in
            Text("\(Fmt.bytes(app.size + leftovers.reduce(0) { $0 + $1.size })) au total. Récupérable depuis la Corbeille.")
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        Button {
            select(app)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(app.lastUsed.map { "Utilisée le \($0.shortLabel)" } ?? "Dernière utilisation inconnue")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Text(Fmt.bytes(app.size)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected?.id == app.id ? AnyShapeStyle(.white.opacity(0.12)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var detail: some View {
        if let app = selected {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.system(size: 17, weight: .bold, design: .rounded))
                            Text("\(app.bundleID) · v\(app.version)").font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Divider().overlay(.white.opacity(0.1))
                    Text("Sera mis à la Corbeille").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    leftoverRow(label: (app.path as NSString).lastPathComponent, size: app.size)
                    if isLoadingLeftovers {
                        ProgressView().controlSize(.small)
                    } else {
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(leftovers) { leftoverRow(label: $0.label, size: $0.size) }
                            }
                        }
                        .frame(maxHeight: 260)
                    }
                    Divider().overlay(.white.opacity(0.1))
                    if isRunning {
                        Label("L'app est ouverte : quitte-la avant de la désinstaller.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(Theme.orange)
                    }
                    HStack {
                        Button("Afficher dans le Finder") { revealInFinder(app.path) }.buttonStyle(GhostButtonStyle())
                        Spacer()
                        Button("Désinstaller") { confirming = true }
                            .buttonStyle(AccentButtonStyle(destructive: true))
                            .disabled(isRunning || isLoadingLeftovers || state.isDeleting)
                    }
                }
            }
        } else {
            Card {
                VStack(spacing: 8) {
                    Text("Choisis une application").font(.system(size: 14, weight: .semibold))
                    Text(state.lastOutcome ?? "Les apps d'Apple ne sont pas listées.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
    }

    private func leftoverRow(label: String, size: Int64) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(Fmt.bytes(size)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.secondaryText)
        }
    }

    private func select(_ app: InstalledApp) {
        selected = app
        leftovers = []
        isLoadingLeftovers = true
        let home = state.home
        Task.detached(priority: .userInitiated) {
            let found = AppInventory.leftovers(for: app, home: home)
            await MainActor.run {
                guard selected?.id == app.id else { return }
                leftovers = found
                isLoadingLeftovers = false
            }
        }
    }
}
