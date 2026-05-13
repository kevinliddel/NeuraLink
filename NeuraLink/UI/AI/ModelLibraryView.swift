//
//  ModelLibraryView.swift
//  NeuraLink
//
//  A dedicated gallery view for managing local AI models.
//  Provides a sleek, immersive interface for downloading and switching models.
//
//  Created by Dedicatus on 10/05/2026.
//

import SwiftUI

struct ModelLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manager = LocalModelDownloadManager.shared
    
    var body: some View {
        ZStack {
            backgroundView
            
            VStack(spacing: 0) {
                headerView
                modelListView
            }
        }
        .preferredColorScheme(.dark)
        .navigationTitle("Model Library")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Sub-views
    
    private var backgroundView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack {
                Circle()
                    .fill(Color.cyan.opacity(0.15))
                    .frame(width: 400, height: 400)
                    .blur(radius: 80)
                    .offset(x: -150, y: -200)
                Spacer()
                Circle()
                    .fill(Color.purple.opacity(0.1))
                    .frame(width: 300, height: 300)
                    .blur(radius: 60)
                    .offset(x: 150, y: 150)
            }
            .ignoresSafeArea()
        }
    }
    
    private var modelListView: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(LocalModelDownloadManager.ModelConfiguration.allCases) { config in
                    card(for: config)
                }
            }
            .padding(20)
            .padding(.bottom, 40)
        }
    }
    
    private func card(for config: LocalModelDownloadManager.ModelConfiguration) -> some View {
        ModelLibraryCard(
            config: config,
            isSelected: manager.selectedConfig == config,
            status: manager.downloadState(for: config),
            diskUsage: manager.diskUsageBytes(for: config),
            onSelect: { select(config) },
            onPause: { manager.pauseDownload() },
            onResume: { manager.resumeDownload() },
            onDelete: { delete() }
        )
    }
    
    private func select(_ config: LocalModelDownloadManager.ModelConfiguration) {
        withAnimation {
            manager.selectConfig(config)
            if case .paused = manager.state {
                manager.resumeDownload()
            } else if !manager.isAvailable {
                manager.startDownload()
            }
        }
    }
    
    private func delete() {
        manager.deleteDownloadedModel()
    }
    
    private var headerView: some View {
        let totalBytes = LocalModelDownloadManager.ModelConfiguration.allCases.reduce(Int64(0)) {
            $0 + manager.diskUsageBytes(for: $1)
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Edge Intelligence")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            Text(
                totalBytes > 0
                    ? "On device: \(formatBytes(totalBytes))"
                    : "Select and download local SLMs."
            )
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            Color.black.opacity(0.3)
                .background(.ultraThinMaterial)
        )
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
