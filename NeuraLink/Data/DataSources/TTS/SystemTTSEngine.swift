//
//  SystemTTSEngine.swift
//  NeuraLink
//
//  AVSpeechSynthesizer wrapper — the always-available fallback that the
//  selector returns when no downloaded model is usable, or that other
//  engines (F5TTSEngine) delegate to when they can't service a request.
//  Lifted from feat/voice-cloning at Phase 2a and adapted to the unified
//  TTSEngineProtocol (push-streaming via onBufferReady, persona-keyed).
//
//  Created by Dedicatus on 29/04/2026.
//

import AVFoundation
import Foundation

final class SystemTTSEngine: NSObject, TTSEngineProtocol {

    var onBufferReady: ((AVAudioPCMBuffer) -> Void)?

    var isReady: Bool { true }

    private let synthesizer = AVSpeechSynthesizer()

    func initialize() async throws {
        // AVSpeechSynthesizer needs no setup — it's ready at allocation.
    }

    func speak(_ text: String, persona: PersonaIdentifier) async throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
            clean.unicodeScalars.contains(where: {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            })
        else { return }

        let resolvedPersona = CharacterPersona.forCharacter(named: persona)
        let language = resolvedPersona.instructions.contains("Japanese") ? "ja-JP" : "en-US"

        // AVSpeechSynthesizer.write() must run on a plain GCD main queue —
        // calling it from Swift's cooperative executor triggers the
        // "unsafeForcedSync called from Swift Concurrent context" runtime trap.
        // Resume the continuation only on the empty-buffer sentinel that the
        // write() callback emits at end-of-utterance (Apple-documented).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    cont.resume()
                    return
                }
                let utterance = AVSpeechUtterance(string: clean)
                let prefix = language.prefix(2)
                let best = AVSpeechSynthesisVoice.speechVoices()
                    .filter { $0.language.hasPrefix(prefix) }
                    .max { $0.quality.rawValue < $1.quality.rawValue }
                utterance.voice = best ?? AVSpeechSynthesisVoice(language: language)
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                utterance.pitchMultiplier = 1.0

                var resumed = false
                self.synthesizer.write(utterance) { [weak self] buffer in
                    guard let self, let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
                    if pcmBuffer.frameLength > 0 {
                        self.onBufferReady?(pcmBuffer)
                    } else if !resumed {
                        resumed = true
                        cont.resume()
                    }
                }
            }
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func shutdown() {
        stop()
    }
}
