//
//  MotionModelCard.swift
//  NeuraLink
//
//  The motion model's download under the "Gesture while speaking" switch:
//  its size and state, a download that first shows the notices the model's
//  licences ask for, and removal. docs/REALTIME_MOTION_PLAN.md, Phase 5.
//
//  Created by Dedicatus on 30/10/2026.
//

import SwiftUI

struct MotionModelCard: View {
    @Bindable var state = MotionModelDownloadState.shared
    @State private var showsNotices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Motion model", systemImage: "cube.transparent")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(Self.sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            statusLine
            actions
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showsNotices) {
            MotionModelNoticesSheet { state.download() }
        }
        .onAppear { state.refresh() }
    }

    @ViewBuilder private var statusLine: some View {
        switch state.phase {
        case .missing:
            Text("Not on this phone yet. Needed for generated gestures.")
                .font(.caption).foregroundStyle(.secondary)
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Downloading \(Int(fraction * 100)) %")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tint(AppTheme.Tint.bond)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            switch state.phase {
            case .missing, .failed:
                Button("Download…") { showsNotices = true }
                    .buttonStyle(.borderless)
            case .downloading:
                Button("Cancel") { state.cancel() }
                    .buttonStyle(.borderless)
            case .ready:
                Button("Remove", role: .destructive) { state.remove() }
                    .buttonStyle(.borderless)
            }
        }
        .font(.subheadline)
    }

    private static var sizeText: String {
        ByteCountFormatter.string(fromByteCount: MotionModelAccess.totalBytes, countStyle: .file)
    }
}

/// The terms the model files carry, shown before the first download.
struct MotionModelNoticesSheet: View {
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("The character's generated gestures come from the ARDY motion model, downloaded to this phone as published by its authors. These files are not part of NeuraLink's licence; the following terms apply to them.")
                        .font(.subheadline)
                }
                Section("Notices") {
                    ForEach(MotionModelNotices.items, id: \.title) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            if let url = item.url {
                                Link(url.host ?? url.absoluteString, destination: url)
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section {
                    Text(MotionModelNotices.builtWith).font(.footnote.weight(.semibold))
                }
            }
            .navigationTitle("Before downloading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        dismiss()
                        onContinue()
                    }
                }
            }
        }
    }
}

enum MotionModelNotices {
    struct Item {
        let title: String
        let detail: String
        let url: URL?
    }

    static let builtWith = "Built with Meta Llama 3."

    static let items: [Item] = [
        Item(title: "ARDY motion model (NVIDIA)",
             detail: "Denoiser and decoder weights under the NVIDIA Open Model License.",
             url: URL(string: "https://huggingface.co/nvidia/ARDY-Core-RP-20FPS-Horizon40")),
        Item(title: "Distilled text encoder (ARDY-mini)",
             detail: "A MiniLM student of ARDY's Llama 3 text conditioning: Meta Llama 3 Community License (teacher lineage), MiniLM under Apache 2.0, and the publisher's composite model terms.",
             url: URL(string: "https://huggingface.co/intsuc/Llama-3-ARDY-Mini-Core40-Browser")),
        Item(title: "Training captions (NVIDIA SEED-Timeline)",
             detail: "CC BY 4.0.",
             url: URL(string: "https://huggingface.co/datasets/nvidia/SEED-Timeline-Annotations")),
        Item(title: "Graph preparation",
             detail: "The downloaded graphs are the published ONNX files with Clip bounds made explicit; nothing else is changed.",
             url: nil)
    ]
}
