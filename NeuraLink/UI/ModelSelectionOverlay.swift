//
//  ModelSelectionOverlay.swift
//  NeuraLink
//
//  Created by Dedicatus on 20/04/2026.
//

import SwiftUI

struct ModelSelectionOverlay: View {
    @Binding var selectedModelURL: URL?
    let models: [VRMModelRegistry.Entry]
    var onSelection: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(models, id: \.url) { entry in
                    ModelCard(
                        entry: entry,
                        isSelected: selectedModelURL == entry.url
                    )
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedModelURL = entry.url
                        }
                        onSelection()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.black)
                .edgesIgnoringSafeArea(.bottom)
        )
        // Set maximum height for the container, adjust padding as needed
        .frame(height: 270)
    }
}

private struct ModelCard: View {
    let entry: VRMModelRegistry.Entry
    let isSelected: Bool

    private var imageURL: URL? {
        let pngURL = entry.url.deletingPathExtension().appendingPathExtension("png")
        return FileManager.default.fileExists(atPath: pngURL.path) ? pngURL : nil
    }

    private var descriptionText: String {
        switch entry.name.lowercased() {
        case "ekaterina": return "温かく、優しいお姉さんタイプ――思いやりがあり、愛情深い"
        case "sonya": return "鋭いツンデレの女王様――高慢な中にも隠れた優しさ"
        default: return "AI Companion"
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background Image
            if let imageURL = imageURL, let uiImage = UIImage(contentsOfFile: imageURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 160, height: 220)
                    .clipped()
            } else {
                Color.gray.opacity(0.3)
                    .frame(width: 160, height: 220)
            }

            // Gradient Overlay
            LinearGradient(
                colors: [.clear, .black.opacity(0.6), .black.opacity(0.9)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(width: 160, height: 220)

            // 18+ Badge
            VStack {
                HStack {
                    Text("18+")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(4)
                    Spacer()
                }
                .padding(8)
                Spacer()
            }

            // Text and Icons
            VStack(spacing: 4) {
                Text(entry.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)

                Text(descriptionText)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 4)

                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Image(systemName: "message.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.white)
                        )

                    Circle()
                        .fill(isSelected ? Color.white : Color.white.opacity(0.2))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Image(systemName: "waveform")
                                .font(.system(size: 10))
                                .foregroundColor(isSelected ? .black : .white)
                        )
                }
                .padding(.top, 4)
            }
            .padding(.bottom, 12)
        }
        .frame(width: 160, height: 220)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2)
        )
        .opacity(isSelected ? 1.0 : 0.6)
    }
}
