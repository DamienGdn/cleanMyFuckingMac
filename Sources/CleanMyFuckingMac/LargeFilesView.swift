import CMFMCore
import SwiftUI

struct LargeFilesView: View {
    private enum Tab: CaseIterable {
        case large, duplicates
        var title: String {
            switch self {
            case .large: return String(localized: "Large and old files")
            case .duplicates: return String(localized: "Duplicates")
            }
        }
    }
    private enum Age: CaseIterable, Identifiable {
        case any, sixMonths, oneYear
        var id: Self { self }
        var title: String {
            switch self {
            case .any: return String(localized: "Any date")
            case .sixMonths: return String(localized: "Older than 6 months")
            case .oneYear: return String(localized: "Older than a year")
            }
        }
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
            PageHeader(title: "Large Files", subtitle: "Heavy, forgotten or duplicate files.") {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
            }

            if state.isScanning {
                Card { ScanProgressRow() }
                Spacer()
            } else if state.tree == nil {
                EmptyState(symbol: "doc.on.doc.fill", title: "Scan needed",
                           message: "Large files and duplicates come from the disk scan.") {
                    Button("Scan My Home Folder") { state.startScan(root: state.home) }.buttonStyle(AccentButtonStyle())
                }
            } else {
                if tab == .large { largeList } else { duplicateList }
                footer
            }
        }
        .onChange(of: tab) { selection = [] }
        .confirmationDialog("Delete \(selectedNodes.count) file(s)?", isPresented: $confirming) {
            Button(state.permanentDelete ? "Delete permanently" : "Move to Trash", role: .destructive) {
                let nodes = selectedNodes
                selection = []
                Task { await state.delete(nodes: nodes) }
            }
        } message: {
            Text("\(Fmt.bytes(selectedNodes.reduce(0) { $0 + $1.size })) in total.")
        }
    }

    private var largeList: some View {
        let files = filtered
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Picker("Size", selection: $minimumMB) {
                    ForEach([50, 100, 500, 1024], id: \.self) { megabytes in
                        Text(megabytes >= 1024 ? String(localized: "≥ 1 GB") : String(localized: "≥ \(megabytes) MB")).tag(megabytes)
                    }
                }
                .fixedSize()
                Picker("Age", selection: $age) {
                    ForEach(Age.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Toggle("Include hidden and system files", isOn: $includeSystem).font(.system(size: 12))
                Spacer()
                Text("\(files.count) files · \(Fmt.bytes(files.reduce(0) { $0 + $1.size }))")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            Card(padding: 8) {
                if files.isEmpty {
                    Text("No file matches these filters.").font(.system(size: 13))
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
            EmptyState(symbol: "doc.on.doc.fill", title: "Comparing files…",
                       message: "Hashing files of the same size.") { ProgressView().controlSize(.small) }
        } else if let groups = state.duplicateGroups {
            if groups.isEmpty {
                EmptyState(symbol: "checkmark.seal.fill", title: "No duplicates",
                           message: "No identical files over 1 MB in your documents.") { EmptyView() }
            } else {
                HStack {
                    Text("\(groups.count) groups · \(Fmt.bytes(groups.reduce(0) { $0 + $1.wasted })) reclaimable")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button("Select All but One Copy") {
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
            EmptyState(symbol: "doc.on.doc.fill", title: "Find duplicates",
                       message: "Compares the content of files over 1 MB in your documents. Hidden folders, the Library and app bundles are skipped.") {
                Button("Find Duplicates") { state.findDuplicates() }.buttonStyle(AccentButtonStyle())
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
        .contextMenu { Button("Show in Finder") { revealInFinder(node.path) } }
    }

    private var footer: some View {
        Card(padding: 14) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selection: \(Fmt.bytes(selectedNodes.reduce(0) { $0 + $1.size }))")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    if let outcome = state.lastOutcome {
                        Text(outcome).font(.system(size: 12)).foregroundStyle(Theme.mint)
                    }
                }
                Spacer()
                if state.isDeleting { ProgressView().controlSize(.small) }
                Button("Delete Selection") { confirming = true }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(selection.isEmpty || state.isDeleting)
            }
        }
    }
}
