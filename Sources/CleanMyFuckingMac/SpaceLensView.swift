import AppKit
import CMFMCore
import SwiftUI

struct SpaceLensView: View {
    @EnvironmentObject private var state: AppState
    @State private var pendingDeletion: FileNode?

    /// Cells drawn in the map; the rest of a directory is still listed on the right.
    private static let maxCells = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Space Lens", subtitle: "Carte de ton disque : plus le bloc est gros, plus il pèse.") {
                Menu {
                    Button("Dossier personnel") { state.startScan(root: state.home) }
                    Button("Disque entier") { state.startScan(root: AppState.dataVolume) }
                    Button("Choisir un dossier…") { chooseFolder() }
                } label: {
                    Label(state.tree == nil ? "Analyser" : "Nouvelle analyse", systemImage: "magnifyingglass")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(state.isScanning)
            }

            if state.isScanning {
                Card { ScanProgressRow() }
                Spacer()
            } else if let focus = state.focus {
                breadcrumb(for: focus)
                HStack(alignment: .top, spacing: 16) {
                    TreemapView(nodes: Array(focus.children.prefix(Self.maxCells)), onOpen: open, onDelete: { pendingDeletion = $0 })
                        .id("\(focus.path)#\(state.treeVersion)")
                    Card(padding: 12) {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(focus.children.enumerated()), id: \.element.id) { index, node in
                                    SizeBarRow(node: node, total: focus.size, color: cellColor(node, index))
                                        .contentShape(Rectangle())
                                        .onTapGesture { open(node) }
                                        .contextMenu { nodeMenu(node) }
                                }
                            }
                        }
                    }
                    .frame(width: 430)
                }
                if let outcome = state.lastOutcome {
                    Text(outcome).font(.system(size: 12)).foregroundStyle(Theme.mint)
                }
            } else {
                EmptyState(symbol: "square.grid.3x3.topleft.filled", title: "Rien d'analysé pour l'instant",
                           message: "Lance une analyse pour voir, dossier par dossier, ce qui remplit ton disque.") {
                    Button("Analyser mon dossier personnel") { state.startScan(root: state.home) }
                        .buttonStyle(AccentButtonStyle())
                }
            }
        }
        .confirmationDialog("Supprimer « \(pendingDeletion?.name ?? "") » ?",
                            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                            presenting: pendingDeletion) { node in
            Button("Mettre à la Corbeille (\(Fmt.bytes(node.size)))", role: .destructive) {
                Task { await state.delete(nodes: [node], permanent: false) }
            }
        } message: { node in
            Text(node.path)
        }
    }

    private func breadcrumb(for focus: FileNode) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(focus.ancestors) { node in
                    if node !== focus.ancestors.first {
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.secondaryText)
                    }
                    Button(node.parent == nil ? node.path : node.name) { state.focus = node }
                        .buttonStyle(GhostButtonStyle())
                }
                Text(Fmt.bytes(focus.size)).font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accent).padding(.leading, 8)
            }
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder private func nodeMenu(_ node: FileNode) -> some View {
        if !node.isAggregate {
            Button("Afficher dans le Finder") { revealInFinder(node.path) }
            Button("Mettre à la Corbeille…", role: .destructive) { pendingDeletion = node }
        }
    }

    private func open(_ node: FileNode) {
        if node.isDirectory, !node.children.isEmpty {
            withAnimation(.easeInOut(duration: 0.2)) { state.focus = node }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Analyser"
        if panel.runModal() == .OK, let url = panel.url {
            state.startScan(root: url.path)
        }
    }
}

func cellColor(_ node: FileNode, _ index: Int) -> Color {
    if node.isAggregate { return .gray }
    return Theme.palette[index % Theme.palette.count]
}

struct TreemapView: View {
    let nodes: [FileNode]
    let onOpen: (FileNode) -> Void
    let onDelete: (FileNode) -> Void
    @State private var hovered: String?

    var body: some View {
        GeometryReader { proxy in
            let rects = Treemap.layout(values: nodes.map { Double($0.size) }, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    let rect = rects[index].insetBy(dx: 1.5, dy: 1.5)
                    if rect.width > 2, rect.height > 2 {
                        cell(node, color: cellColor(node, index), size: rect.size)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func cell(_ node: FileNode, color: Color, size: CGSize) -> some View {
        let isHovered = hovered == node.id
        return RoundedRectangle(cornerRadius: min(10, min(size.width, size.height) / 4), style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(isHovered ? 1 : 0.85), color.opacity(isHovered ? 0.75 : 0.5)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .topLeading) {
                if size.width > 78, size.height > 40 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(Fmt.bytes(node.size)).font(.system(size: 11)).opacity(0.85)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .padding(8)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? node.id : (hovered == node.id ? nil : hovered) }
            .onTapGesture { onOpen(node) }
            .help("\(node.name) — \(Fmt.bytes(node.size))")
            .contextMenu {
                if !node.isAggregate {
                    Button("Afficher dans le Finder") { revealInFinder(node.path) }
                    Button("Mettre à la Corbeille…", role: .destructive) { onDelete(node) }
                }
            }
    }
}
