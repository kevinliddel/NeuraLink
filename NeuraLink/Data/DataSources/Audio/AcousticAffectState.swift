//
//  AcousticAffectState.swift
//  NeuraLink
//
//  The current read on how the user sounds (docs/LLM_VOICE.md). Each
//  engine's VAD hands over the utterance's features; the transcript then
//  adds the word count and the turn is classified against the user's own
//  baseline. The local prompt builder, the Realtime handler and the local
//  TTS engines read the result here.
//
//  Created by Dedicatus on 16/10/2026.
//

import Foundation
import Observation

@Observable
final class AcousticAffectState {
    static let shared = AcousticAffectState()

    private(set) var current: AffectLabel = .neutral
    private(set) var baseline = AcousticBaseline()
    private(set) var lastFeatures: AcousticFeatures?
    private var pending: AcousticFeatures?
    /// The last label the Realtime session was told about.
    private var announced: AffectLabel = .neutral

    private init() {}

    var modulation: TTSModulation {
        AffectSettings.shared.isEnabled ? AcousticAffect.modulation(for: current) : .none
    }

    /// The VAD's utterance, before its transcript exists.
    func noteUtterance(_ features: AcousticFeatures) {
        guard AffectSettings.shared.isEnabled else { return }
        pending = features
    }

    /// The transcript for the pending utterance: classify and learn.
    @discardableResult
    func noteTranscript(_ transcript: String) -> AffectLabel {
        guard AffectSettings.shared.isEnabled, var features = pending else { return current }
        pending = nil
        features.wordCount = AcousticAffect.wordCount(of: transcript)
        let label = AcousticAffect.classify(features, baseline: baseline)
        baseline.absorb(features)
        lastFeatures = features
        current = label
        nlLog(
            "[Affect] \(label.rawValue) — \(String(format: "%.1f", features.durationSec)) s, energy \(String(format: "%.3f", features.energyMean)), "
                + "pitch \(features.pitchMeanHz.map { String(format: "%.0f Hz ±%.0f", $0, features.pitchStdHz) } ?? "unvoiced"), "
                + "pauses \(features.pauseCount), words \(features.wordCount ?? 0)",
            level: .info)
        return label
    }

    /// The per-turn block for the local prompt; empty when neutral.
    func promptBlock() -> String {
        guard AffectSettings.shared.isEnabled, let tag = AcousticAffect.tag(for: current) else { return "" }
        return "\n\(tag)\n"
    }

    /// A line for the Realtime conversation only when the read changed:
    /// the new tag, or the clear line when back to neutral.
    func realtimeTagIfChanged() -> String? {
        guard AffectSettings.shared.isEnabled, current != announced else { return nil }
        announced = current
        return AcousticAffect.tag(for: current) ?? AcousticAffect.clearTag
    }

    /// Session over: the Realtime side starts unannounced again.
    func resetAnnouncement() {
        announced = .neutral
    }

    /// Tests.
    func reset() {
        current = .neutral
        baseline = AcousticBaseline()
        lastFeatures = nil
        pending = nil
        announced = .neutral
    }
}
