//
//  LocalVoicePreview.swift
//  NeuraLink
//
//  Speaks a finished text through the local voice engine: the persona
//  settings voice preview, and a past message replayed from the chat
//  history. The text is already complete, so nothing waits on a model.
//  The only wait is rendering, and it is kept short:
//    - the text is spoken chunk by chunk (SpeechChunker), so audio starts
//      after the first clause and the rest renders while it plays;
//    - the voice goes straight to the engine, so trying an unsaved voice
//      no longer rewrites the saved one or borrows the chat's audio callback;
//    - background memory generations pause while it speaks, because they
//      run on the same CPU cores as VOICEVOX;
//    - `warmUp` loads the voice before the first tap.
//
//  Created by Dedicatus on 20/10/2026.
//

import AVFoundation
import Observation

@Observable
@MainActor
final class LocalVoicePreview {

    enum Voice: Hashable {
        case voicevox(speakerID: Int)
        case openVoice(name: String)

        /// The voice a live turn would use for `character` right now; nil
        /// when the English voice pack is not installed yet.
        static func current(for character: PersonaIdentifier) -> Voice? {
            if LocalModelDownloadManager.shared.selectedConfig == .llmJp3 {
                return .voicevox(speakerID: VoiceVoxSpeaker.speakerID(for: character))
            }
            guard OpenVoiceModelAccess.isAvailable else { return nil }
            return .openVoice(name: OpenVoiceVoicePreset.preset(for: character).identifier)
        }
    }

    let player = LocalTTSPreviewPlayer()
    /// From the start of a run until its last chunk is rendered.
    private(set) var isRendering = false
    private var task: Task<Void, Never>?
    /// Bumped by every run and by `stop()`; a run only touches shared state
    /// while it still owns the latest token.
    private var renderToken = 0

    /// Waiting for the first audio of a run.
    var isLoading: Bool { isRendering && !player.isSpeaking }
    /// A run is rendering or its audio is still playing.
    var isActive: Bool { isRendering || player.isSpeaking }

    /// Starts speaking `text`, replacing any run in progress.
    func start(_ text: String, voice: Voice) {
        stop()
        task = Task { [weak self] in await self?.speak(text, voice: voice) }
    }

    func stop() {
        task?.cancel()
        task = nil
        renderToken += 1
        isRendering = false
        player.stop()
    }

    /// Speaks `text` in the caller's task. Cancelling the task stops it after
    /// the chunk being rendered; that chunk is dropped, not played.
    func speak(_ text: String, voice: Voice) async {
        let chunks = SpeechChunker.chunks(text)
        guard !chunks.isEmpty else { return }
        renderToken += 1
        let token = renderToken
        isRendering = true
        player.beginStream()
        LocalLLMManager.shared.beginStandaloneSpeech()
        defer {
            LocalLLMManager.shared.endStandaloneSpeech()
            if renderToken == token {
                isRendering = false
                player.endStream()
            }
        }
        do {
            try await render(chunks, voice: voice, token: token)
        } catch is CancellationError {
            // Stopped by the user.
        } catch {
            nlLog("[VoicePreview] Local voice failed: \(error)", level: .error)
        }
    }

    /// Loads `voice` so the first tap doesn't pay for it. Never downloads:
    /// a voice that isn't on disk yet is left for the tap to fetch.
    func warmUp(_ voice: Voice) async {
        switch voice {
        case .voicevox(let speakerID):
            guard VoiceVoxModelAccess.isDictionaryAvailable,
                  VoiceVoxModelAccess.isSpeakerAvailable(speakerID: speakerID) else { return }
            await VoiceVoxEngine.shared.warmUp(speakerID: speakerID)
        case .openVoice:
            guard OpenVoiceModelAccess.isAvailable else { return }
            try? await OpenVoiceEngine.shared.initialize()
        }
    }

    private func render(_ chunks: [String], voice: Voice, token: Int) async throws {
        switch voice {
        case .voicevox(let speakerID):
            let engine = VoiceVoxEngine.shared
            try await engine.initialize()
            for chunk in chunks {
                try Task.checkCancellation()
                let wav = try await engine.synthesize(text: chunk, speakerID: speakerID)
                guard renderToken == token, !Task.isCancelled else { return }
                if let buffer = AudioDataConverter.pcmBuffer(from: wav) { player.schedule(buffer) }
            }
        case .openVoice(let name):
            let engine = OpenVoiceEngine.shared
            try await engine.initialize()
            for chunk in chunks {
                try Task.checkCancellation()
                try await engine.speak(chunk, voiceName: name) { [weak self] buffer in
                    DispatchQueue.main.async {
                        guard let self, self.renderToken == token else { return }
                        self.player.schedule(buffer)
                    }
                }
            }
        }
    }
}
