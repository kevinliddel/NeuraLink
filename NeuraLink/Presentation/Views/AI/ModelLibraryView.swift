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
    @State private var showCleanAllConfirmation = false

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
        .confirmationDialog(
            "Delete all cached models?",
            isPresented: $showCleanAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All (\(formatBytes(manager.totalCacheBytes)))",
                   role: .destructive) {
                deleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(formatBytes(manager.totalCacheBytes)) of storage. You'll need to re-download any model you want to use again.")
        }
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
        .scrollIndicators(.hidden)
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
            onDelete: { delete(config) }
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

    private func delete(_ config: LocalModelDownloadManager.ModelConfiguration) {
        // If we're deleting the currently loaded model, drop the engine first
        // so its mmap'd file handle is released — otherwise iOS defers disk
        // reclamation until the process unmaps the file (typically next launch).
        if config == manager.selectedConfig {
            LocalLLMManager.shared.unload()
        }
        withAnimation {
            manager.deleteModel(config)
        }
    }

    private func deleteAll() {
        // Always unload — at most one engine is active and we don't know which.
        LocalLLMManager.shared.unload()
        withAnimation {
            manager.deleteAllModels()
        }
    }

    private var headerView: some View {
        let totalBytes = manager.totalCacheBytes
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
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

            Spacer()

            if totalBytes > 0 {
                Button {
                    showCleanAllConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red.opacity(0.9))
                        .frame(width: 40, height: 40)
                        .background(Color.red.opacity(0.15))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.red.opacity(0.4), lineWidth: 1))
                }
                .accessibilityLabel("Clean all cached models")
            }
        }
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
