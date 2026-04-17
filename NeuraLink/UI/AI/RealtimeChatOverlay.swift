//
//  RealtimeChatOverlay.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import SwiftUI

struct RealtimeChatOverlay: View {
    let aiState = RealtimeChatState.shared
    let aiManager = OpenAIRealtimeManager.shared
    
    var body: some View {
        VStack {
            Spacer()
            
            // Transcription area
            if !aiState.aiTranscript.isEmpty || !aiState.userTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if !aiState.userTranscript.isEmpty {
                        Text("You: ")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                        + Text(aiState.userTranscript)
                            .font(.body)
                    }
                    
                    if !aiState.aiTranscript.isEmpty {
                        Text("AI: ")
                            .font(.caption.bold())
                            .foregroundStyle(.purple)
                        + Text(aiState.aiTranscript)
                            .font(.body)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            // Mic and Status Controls
            HStack(spacing: 20) {
                // Connection/Status Indicator
                VStack(alignment: .leading) {
                    Text(aiState.status.label)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor.opacity(0.2))
                        .foregroundStyle(statusColor)
                        .clipShape(Capsule())
                }
                
                Spacer()
                
                // Main Interaction Button
                Button {
                    if aiState.status == .disconnected {
                        aiManager.connect()
                    } else {
                        aiManager.disconnect()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 60, height: 60)
                            .shadow(color: statusColor.opacity(0.3), radius: 10)
                        
                        Image(systemName: aiState.status == .disconnected ? "mic.fill" : "stop.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                        
                        // Pulse animation for audio
                        if aiState.status == .speaking || aiState.status == .listening {
                            Circle()
                                .stroke(statusColor, lineWidth: 2)
                                .scaleEffect(1.0 + CGFloat(aiState.audioLevel * 1.5))
                                .opacity(Double(1.0 - aiState.audioLevel))
                        }
                    }
                }
                .animation(.spring(), value: aiState.audioLevel)
                
                Spacer()
                
                // Clear History Button
                Button {
                    aiState.reset()
                } label: {
                    Image(systemName: "trash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32))
        }
        .ignoresSafeArea(edges: .bottom)
        .animation(.default, value: aiState.status.label)
    }
    
    private var statusColor: Color {
        switch aiState.status {
        case .disconnected: return .gray
        case .connecting: return .yellow
        case .ready: return .green
        case .listening: return .blue
        case .thinking: return .orange
        case .speaking: return .purple
        case .error: return .red
        }
    }
}
