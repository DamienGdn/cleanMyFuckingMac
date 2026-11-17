import CMFMCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var state: AppState

    private var isBusy: Bool { state.isScanning || state.isCleanScanning || state.isLoadingApps }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Dashboard", subtitle: "Where your space goes, and what you can get back.") {
                    Button("Smart Clean") { state.requestSmartClean() }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(isBusy || state.isDeleting)
                        .help("Cleans safe caches and logs in one click, after confirmation.")
                    Button(isBusy ? "Scanning…" : "Smart Scan") { state.smartScan() }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(isBusy)
                }

                if state.isDeleting {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Cleaning…").font(.system(size: 12)) }
                } else if let outcome = state.lastOutcome {
                    Text(outcome).font(.system(size: 12)).foregroundStyle(Theme.mint)
                }

                if !state.hasFullDiskAccess { FullDiskAccessBanner() }

                HStack(alignment: .top, spacing: 20) {
                    Card {
                        HStack(spacing: 26) {
                            ZStack {
                                RingGauge(fraction: state.disk.usedFraction)
                                VStack(spacing: 2) {
                                    Text("\(Int((state.disk.usedFraction * 100).rounded())) %")
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                    Text("used").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                                }
                            }
                            .frame(width: 150, height: 150)
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Macintosh HD").font(.system(size: 17, weight: .semibold, design: .rounded))
                                stat("Used", Fmt.bytes(state.disk.used))
                                stat("Free", Fmt.bytes(state.disk.free))
                                stat("Capacity", Fmt.bytes(state.disk.total))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 14) {
                        SummaryTile(symbol: "sparkles", title: "Cleanable",
                                    value: state.isCleanScanning ? "…" : Fmt.bytes(state.cleanableTotal),
                                    hint: String(localized: "caches, logs, trash"), target: .cleanup)
                        SummaryTile(symbol: "doc.on.doc.fill", title: "Large Files",
                                    value: state.tree == nil ? "—" : "\(state.largeFiles.count)",
                                    hint: state.tree == nil ? String(localized: "run a Smart Scan") : String(localized: "over 50 MB"),
                                    target: .files)
                        SummaryTile(symbol: "xmark.app.fill", title: "Applications",
                                    value: state.isLoadingApps ? "…" : "\(state.apps.count)",
                                    hint: Fmt.bytes(state.apps.reduce(0) { $0 + $1.size }), target: .apps)
                    }
                    .frame(width: 330)
                }

                if state.isScanning {
                    Card { ScanProgressRow() }
                } else if let tree = state.tree {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("What takes the most space").font(.system(size: 15, weight: .semibold, design: .rounded))
                                Spacer()
                                Button("Explore in Space Lens") { state.focus = tree; state.section = .lens }
                                    .buttonStyle(GhostButtonStyle())
                            }
                            ForEach(Array(tree.children.prefix(8).enumerated()), id: \.element.id) { index, node in
                                SizeBarRow(node: node, total: tree.size, color: Theme.palette[index % Theme.palette.count])
                            }
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 13))
        .frame(maxWidth: 220)
    }
}

struct FullDiskAccessBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill").font(.system(size: 22)).foregroundStyle(Theme.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Disk Access not granted").font(.system(size: 13, weight: .semibold))
                    Text("Without it, macOS hides Mail, Safari, the Trash and app data: sizes are underestimated.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Open Settings") { state.openFullDiskAccessSettings() }.buttonStyle(GhostButtonStyle())
                Button("Check Again") { state.refreshSystem() }.buttonStyle(GhostButtonStyle())
            }
        }
    }
}

struct SummaryTile: View {
    @EnvironmentObject private var state: AppState
    let symbol: String
    let title: LocalizedStringKey
    let value: String
    let hint: String
    let target: AppSection

    var body: some View {
        Button { state.section = target } label: {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        Text(value).font(.system(size: 19, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    Text(hint).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ScanProgressRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let progress = state.scanProgress.snapshot
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scanning \(state.scanRoot)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(progress.files.formatted()) files · \(Fmt.bytes(progress.bytes))")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                }
                Spacer()
                Button("Cancel") { state.cancelScan() }.buttonStyle(GhostButtonStyle())
            }
        }
    }
}

/// One line of a size ranking: icon, name, proportional bar, size.
struct SizeBarRow: View {
    let node: FileNode
    let total: Int64
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.isAggregate ? "square.stack.3d.up.fill" : node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(color).frame(width: 18)
            Text(node.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                .frame(width: 190, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07))
                    Capsule().fill(color.opacity(0.85))
                        .frame(width: max(3, proxy.size.width * (total > 0 ? CGFloat(node.size) / CGFloat(total) : 0)))
                }
            }
            .frame(height: 6)
            Text(Fmt.bytes(node.size)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .frame(height: 24)
    }
}
