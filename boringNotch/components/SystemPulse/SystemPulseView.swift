//
//  SystemPulseView.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct SystemPulseView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var manager = SystemPulseManager.shared

    var body: some View {
        HStack(spacing: 12) {
            iconTile
            panel
        }
        .font(.system(.body, design: .rounded))
        .onAppear { manager.start() }
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
                    Image(systemName: manager.snapshot.severity.symbol)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundColor(manager.snapshot.severity.color)

                    Text("PULSE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.gray)
                }
            }
            .frame(width: 70, height: 70)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Refresh System Pulse")
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10]))
            .overlay {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .frame(width: 430)
            .transaction { transaction in
                transaction.animation = vm.animation
            }
    }

    private var content: some View {
        let snapshot = manager.snapshot

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("System Pulse")
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                statusPill(snapshot.thermalLabel, color: snapshot.severity.color)

                Spacer(minLength: 0)

                Text(manager.sensorStatus)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.gray.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(spacing: 10) {
                metric(
                    icon: "fan",
                    title: "Fan L",
                    text: snapshot.fanRPMs[safe: 0].flatMap { $0 }.map { "\($0) RPM" } ?? "—",
                    color: snapshot.fanRPMs[safe: 0].flatMap { $0 } == nil ? .gray : snapshot.severity.color
                )

                metric(
                    icon: "fan",
                    title: "Fan R",
                    text: snapshot.fanRPMs[safe: 1].flatMap { $0 }.map { "\($0) RPM" } ?? "—",
                    color: snapshot.fanRPMs[safe: 1].flatMap { $0 } == nil ? .gray : snapshot.severity.color
                )

                metric(
                    icon: "thermometer.medium",
                    title: "CPU Avg",
                    text: snapshot.temperatureCelsius.map { "\(Int($0.rounded()))°C" } ?? "—",
                    color: snapshot.temperatureCelsius == nil ? .gray : snapshot.severity.color
                )
            }

            if let topProcess = snapshot.topProcess {
                HStack(spacing: 6) {
                    Image(systemName: "flame")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Top CPU")
                        .foregroundStyle(.gray)
                    Text("\(topProcess.displayName) · \(Int(topProcess.cpuPercent.rounded()))%")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(topProcess.cpuPercent >= 80 ? .orange : .gray)
            }
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.07), in: Capsule())
    }

    private func metric(icon: String, title: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .foregroundStyle(.gray)
            Text(text)
                .fontWeight(.semibold)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(color)
        .lineLimit(1)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
