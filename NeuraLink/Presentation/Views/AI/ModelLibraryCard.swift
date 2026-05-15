//
//  ModelLibraryCard.swift
//  NeuraLink
//
//  A premium, Apple-style card for a single AI model.
//  Shows status, progress, and technical specs.
//
//  Created by Dedicatus on 10/05/2026.
//

import SwiftUI

struct ModelLibraryCard: View {
    let config: LocalModelDownloadManager.ModelConfiguration
    let isSelected: Bool
    let status: LocalModelDownloadManager.DownloadState
    let diskUsage: Int64

    var onSelect: () -> Void
    var onPause: () -> Void
    var onResume: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(config.rawValue)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text(config.quantizationLabel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(4)
                }

                Spacer()

                statusIcon
            }

            Text(config.description)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(2)

            Divider().background(Color.white.opacity(0.1))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ESTIMATED SIZE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                    Text(String(format: "%.1f GB", config.estimatedSizeGB))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }

                Spacer()

                if diskUsage > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("ON DISK")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.4))
                        Text(formatBytes(diskUsage))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.cyan)
                    }
                }
            }

            if case .downloading(let progress) = status {
                VStack(spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .cyan))
                        .scaleEffect(x: 1, y: 1.5, anchor: .center)

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                }
                .transition(.opacity.combined(with: .scale))
                
                if isSelected {
                    HStack {
                        Button(action: onPause) {
                            Label("Pause", systemImage: "pause.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(8)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 20))
                    }
                }
            } else if case .paused(let progress) = status {
                VStack(spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .cyan))
                        .scaleEffect(x: 1, y: 1.5, anchor: .center)

                    Text("Paused")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                }

                if isSelected {
                    HStack {
                        Button(action: onResume) {
                            Label("Resume", systemImage: "play.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(8)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 20))
                    }
                }
            } else if isSelected {
                HStack {
                    if status == .ready {
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.2))
                                .cornerRadius(8)
                        }
                    } else if status == .bundled {
                        Label("Built-in", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.green)
                    } else {
                        Button(action: onSelect) {
                            Text("Download")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Color.white)
                                .cornerRadius(12)
                        }
                    }

                    Spacer()

                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 20))
                }
            } else {
                Button(action: onSelect) {
                    Text("Select Model")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                }
            }
        }
        .padding(20)
        .background(
            ZStack {
                Color.black.opacity(0.4)
                RoundedRectangle(cornerRadius: 24)
                    .stroke(
                        isSelected ? Color.cyan.opacity(0.5) : Color.white.opacity(0.1),
                        lineWidth: 1.5)
            }
        )
        .background(.ultraThinMaterial)
        .cornerRadius(24)
        .shadow(
            color: isSelected ? .cyan.opacity(0.2) : .black.opacity(0.2), radius: 10, x: 0, y: 5
        )
        .animation(.spring(), value: status)
        .animation(.spring(), value: isSelected)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .ready, .bundled:
            Image(systemName: "cpu.fill")
                .foregroundColor(.cyan)
        case .downloading:
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color.cyan, lineWidth: 2)
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(360))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: true)
        case .paused:
            Image(systemName: "pause.circle")
                .foregroundColor(.white.opacity(0.6))
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .foregroundColor(.white.opacity(0.3))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
