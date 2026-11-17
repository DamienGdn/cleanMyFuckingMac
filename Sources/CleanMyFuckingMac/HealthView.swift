import CMFMCore
import SwiftUI

extension HealthKPI.Status {
    var color: Color {
        switch self {
        case .good: return Theme.mint
        case .warning: return Theme.orange
        case .critical: return Theme.danger
        }
    }

    var label: String {
        switch self {
        case .good: return String(localized: "All good")
        case .warning: return String(localized: "Needs attention")
        case .critical: return String(localized: "Action required")
        }
    }
}

struct HealthView: View {
    @EnvironmentObject private var monitor: SystemMonitor

    private static let columns = [GridItem(.adaptive(minimum: 250), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Mac Health", subtitle: "\(SystemInfo.modelIdentifier()) · \(ProcessInfo.processInfo.operatingSystemVersionString)") {
                Button("Refresh") { monitor.refreshHealth() }.buttonStyle(GhostButtonStyle())
            }
            if let report = monitor.health {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Card {
                            HStack(spacing: 24) {
                                ZStack {
                                    Circle().stroke(.white.opacity(0.1), lineWidth: 14)
                                    Circle().trim(from: 0, to: Double(report.score) / 100)
                                        .stroke(report.worst.color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                    VStack(spacing: 0) {
                                        Text("\(report.score)").font(.system(size: 38, weight: .bold, design: .rounded))
                                        Text("out of 100").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                                    }
                                }
                                .frame(width: 130, height: 130)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(report.worst.label).font(.system(size: 22, weight: .bold, design: .rounded))
                                        .foregroundStyle(report.worst.color)
                                    let issues = report.kpis.filter { $0.status != .good }
                                    if issues.isEmpty {
                                        Text("No indicator on alert.").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                                    }
                                    ForEach(issues) { kpi in
                                        Label("\(kpi.title): \(kpi.detail)", systemImage: "exclamationmark.triangle.fill")
                                            .font(.system(size: 12)).foregroundStyle(kpi.status.color)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        LazyVGrid(columns: Self.columns, spacing: 14) {
                            ForEach(report.kpis) { kpi in
                                Card(padding: 14) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Image(systemName: kpi.symbol).font(.system(size: 16)).foregroundStyle(kpi.status.color)
                                            Text(kpi.title).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                                            Spacer()
                                            Circle().fill(kpi.status.color).frame(width: 8, height: 8)
                                        }
                                        Text(kpi.value).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                                        Text(kpi.detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                                            .lineLimit(2, reservesSpace: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            } else {
                EmptyState(symbol: "heart.text.square.fill", title: "Running diagnostics…", message: "Reading battery, disk and memory.") {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}
