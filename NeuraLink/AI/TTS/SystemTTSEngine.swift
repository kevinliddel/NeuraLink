//
//  SystemTTSEngine.swift
//  NeuraLink
//
//  Created by Antigravity on 29/04/2026.
//

import AVFoundation
import Foundation

/// A TTS engine that uses Apple's native AVSpeechSynthesizer.
final class SystemTTSEngine: NSObject, TTSProtocol {
    private let synthesizer = AVSpeechSynthesizer()
    
    var onBufferReady: ((AVAudioPCMBuffer) -> Void)?
    
    var isReady: Bool { true }
    
    func speak(_ text: String, for characterName: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              clean.unicodeScalars.contains(where: {
                  CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
              })
        else { return }

        let persona = CharacterPersona.forCharacter(named: characterName)
        let language = persona.instructions.contains("Japanese") ? "ja-JP" : "en-US"

        // AVSpeechSynthesizer.write() must be called from a plain GCD main-queue
        // context — calling it inside Swift’s cooperative executor triggers
        // "unsafeForcedSync called from Swift Concurrent context".
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let utterance = AVSpeechUtterance(string: clean)

            // Prefer the highest-quality available voice for the language.
            let best = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix(language.prefix(2)) }
                .max { a, b in a.quality.rawValue < b.quality.rawValue }
            utterance.voice = best ?? AVSpeechSynthesisVoice(language: language)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.0

            self.synthesizer.write(utterance) { [weak self] buffer in
                guard let self = self,
                      let pcmBuffer = buffer as? AVAudioPCMBuffer,
                      pcmBuffer.frameLength > 0 else { return }
                self.onBufferReady?(pcmBuffer)
            }
        }
    }
    
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
