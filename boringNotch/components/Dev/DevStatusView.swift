//
//  DevStatusView.swift
//  boringNotch
//
//  Compact local developer status for the active repository.
//

import Defaults
import SwiftUI

struct DevStatusView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var manager = DevStatusManager.shared

    var body: some View {
        HStack(spacing: 12) {
            iconTile
            panel
        }
        .font(.system(.body, design: .rounded))
        .onAppear {
            manager.refreshNow()
        }
    }

    private var iconTile: some View {
        Button {
            manager.refreshNow()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )

                VStack(spacing: 8) {
                    Image(systemName: manager.activeStatus?.hasChanges == true ? "hammer.fill" : "checkmark.seal.fill")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundColor(manager.activeStatus?.hasChanges == true ? .orange : .effectiveAccent)

                    Text(manager.isRefreshing ? "SCAN" : "DEV")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.gray)
                }
            }
            .frame(width: 70, height: 70)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Refresh Dev Status")
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10]))
            .overlay {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
    }

    @ViewBuilder
    private var content: some View {
        if let status = manager.activeStatus {
            activeRepository(status)
        } else if let error = manager.lastError {
            emptyState(icon: "exclamationmark.triangle.fill", title: "Dev Mode paused", subtitle: error)
        } else if manager.isRefreshing {
            emptyState(icon: "arrow.triangle.2.circlepath", title: "Scanning projects…", subtitle: "Looking for Git repos under \(Defaults[.devProjectsRoot]).")
        } else {
            emptyState(icon: "folder.badge.questionmark", title: "No Git repos found", subtitle: "Check Settings → Dev or rebuild after changing folder permissions.")
        }
    }

    private func activeRepository(_ status: DevRepositoryStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(status.displayName)
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                branchPill(status.branch)

                Spacer(minLength: 0)

                if manager.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                }
            }

            HStack(spacing: 10) {
                metric(
                    icon: status.hasChanges ? "circle.fill" : "checkmark.circle.fill",
                    text: status.hasChanges ? "\(status.dirtyCount) changes" : "clean",
                    color: status.hasChanges ? .orange : .green
                )
                metric(icon: "number", text: status.lastCommitShortHash, color: .gray)
                metric(icon: "clock", text: relative(status.candidate.latestSourceModification), color: .gray)
            }

            Text(status.candidate.path.path)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.gray.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)

            recentRepositories
        }
    }

    private var recentRepositories: some View {
        let repos = Array(manager.repositories.sorted { $0.latestSourceModification > $1.latestSourceModification }.prefix(3))

        return HStack(spacing: 6) {
            ForEach(repos) { repo in
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                    Text(repo.name)
                        .lineLimit(1)
                }
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.gray)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white, .gray)
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.gray)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
    }

    private func branchPill(_ branch: String) -> some View {
        Text(branch)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.gray)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.07), in: Capsule())
    }

    private func metric(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(color)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    DevStatusView().environmentObject(BoringViewModel())
}

struct DevHomeSummaryView: View {
    @ObservedObject private var manager = DevStatusManager.shared

    var body: some View {
        Group {
            if let status = manager.activeStatus {
                HStack(spacing: 8) {
                    Image(systemName: status.hasChanges ? "circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(status.hasChanges ? .orange : .green)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(status.displayName)
                                .font(.system(.caption, design: .rounded))
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(status.branch)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.gray)
                                .lineLimit(1)
                        }

                        HStack(spacing: 6) {
                            Text(status.hasChanges ? "\(status.dirtyCount) changes" : "clean")
                                .font(.system(.caption2, design: .monospaced))
                                .fontWeight(status.hasChanges ? .semibold : .regular)
                                .foregroundStyle(status.hasChanges ? .orange : .green)
                            Text("# \(status.lastCommitShortHash)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.gray)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .onAppear { manager.refreshNow() }
            }
        }
    }
}
