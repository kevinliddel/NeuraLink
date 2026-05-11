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
            status: status(for: config),
            diskUsage: manager.diskUsageBytes(for: config),
            onSelect: { select(config) },
            onDelete: { delete() }
        )
    }
    
    private func status(for config: LocalModelDownloadManager.ModelConfiguration) -> LocalModelDownloadManager.DownloadState {
        (manager.selectedConfig == config) ? manager.state : .notDownloaded
    }
    
    private func select(_ config: LocalModelDownloadManager.ModelConfiguration) {
        withAnimation {
            manager.selectConfig(config)
            if !manager.isAvailable {
                manager.startDownload()
            }
        }
    }
    
    private func delete() {
        manager.deleteDownloadedModel()
    }
    
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Edge Intelligence")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            Text("Select and download local AI models.")
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
}
