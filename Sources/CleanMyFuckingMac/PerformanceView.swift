import AppKit
import CMFMCore
import SwiftUI

struct PerformanceView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var launchItems: [LaunchItem] = []
    @State private var pendingRemoval: LaunchItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Performance", subtitle: "Memory, hungry processes and startup programs.") {
                EmptyView()
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        gaugeCard("Memory", fraction: monitor.memory.usedFraction,
                                  detail: String(localized: "\(Fmt.bytes(monitor.memory.used))\nof \(Fmt.bytes(monitor.memory.total))"))
                        gaugeCard("Processor", fraction: monitor.cpu,
                                  detail: "↓ \(MenuBarView.rate(monitor.downloadRate))\n↑ \(MenuBarView.rate(monitor.uploadRate))")
                    }
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Most memory-hungry apps").font(.system(size: 13, weight: .semibold)).padding(.leading, 4)
                            ScrollView {
                                LazyVStack(spacing: 0) { ForEach(monitor.topByMemory) { loadRow($0) } }
                            }
                        }
                    }
                }
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Launched at startup (\(launchItems.count))").font(.system(size: 13, weight: .semibold)).padding(.leading, 4)
                        ScrollView {
                            LazyVStack(spacing: 0) { ForEach(launchItems) { launchRow($0) } }
                        }
                    }
                }
                .frame(width: 470)
            }
        }
        .task {
            launchItems = SystemInfo.launchItems(home: state.home)
        }
        .confirmationDialog("Remove “\(pendingRemoval?.label ?? "")” from startup?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { item in
            Button("Move to Trash", role: .destructive) {
                Task {
                    let outcome = await state.delete([DeletionRequest(path: item.path, size: 0, permanent: false)])
                    if outcome.removed.contains(item.path) { launchItems.removeAll { $0.id == item.id } }
                }
            }
        } message: { item in
            Text("The file \(item.path) goes to the Trash. Takes effect at next login.")
        }
    }

    private func gaugeCard(_ title: LocalizedStringKey, fraction: Double, detail: String) -> some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    RingGauge(fraction: fraction, lineWidth: 9)
                    Text("\(Int((fraction * 100).rounded())) %").font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func loadRow(_ load: AppLoad) -> some View {
        // Only regular apps get a Quit button; daemons and helpers are left alone.
        let app = load.runningApplication
        return HStack(spacing: 10) {
            Text(load.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(String(format: "%.0f %% CPU", load.cpu)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondaryText)
            Text(Fmt.bytes(load.memory)).font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 78, alignment: .trailing)
            Button("Quit") {
                Log.info("performance", "Quit requested: \(load.name)")
                app?.terminate()
            }
            .buttonStyle(GhostButtonStyle())
            .opacity(app == nil ? 0 : 1)
            .disabled(app == nil)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private func launchRow(_ item: LaunchItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isUserOwned ? "person.fill" : "gearshape.2.fill")
                .foregroundStyle(item.isUserOwned ? Theme.mint : Theme.secondaryText).frame(width: 18)
                .help(item.isUserOwned ? "User agent" : "System agent (admin rights required)")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(item.program).font(.system(size: 10)).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Button("Finder") { revealInFinder(item.path) }.buttonStyle(GhostButtonStyle())
            if item.isUserOwned {
                Button("Remove") { pendingRemoval = item }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
    }
}
