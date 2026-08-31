//
//  SongRecognitionManager.swift
//  NeuraLink
//
//  Ambient song recognition (Shazam catalog) with an in-character persona
//  reaction — the app's take on Google's song search, but lively.
//
//  Flow: HUD button or the `identify_song` tool call → SHManagedSession
//  records a snippet and matches it against the Shazam catalog → the result
//  drives `phase` (rendered by SongRecognitionOverlay as a pop-up card with
//  Apple Music / YouTube links) → the matched title is announced in the
//  persona's own voice (deterministic TTS, never an LLM turn).
//
//  Created by Dedicatus on 31/08/2026.
//

import AVFAudio
import Foundation
import ShazamKit

/// Orchestrates one-shot song recognition and the persona's reaction to it.
@Observable
final class SongRecognitionManager {

    static let shared = SongRecognitionManager()

    /// UI-facing state machine consumed by `SongRecognitionOverlay`.
    enum Phase: Equatable {
        case idle
        case listening
        case matched(RecognizedSong)
        case noMatch
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Where the request came from. A skill-initiated recognition returns its
    /// summary through the tool-call result (the AI speaks it), so only
    /// HUD-initiated ones inject a separate reaction event into the chat.
    private enum Source { case hudButton, skill }

    private var managedSession: SHManagedSession?

    /// Set by the watchdog before it cancels the session, so the resulting
    /// `.error` is reported as a plain no-match instead of a failure.
    private var timedOut = false

    /// Max listen window before giving up. Shazam usually matches within
    /// ~4–10 s of clean audio; anything longer means it won't match at all.
    private static let listenTimeout: TimeInterval = 18

    // Title-announcement playback (persona-voice TTS, no LLM turn).
    private let cloudAnnouncer = VoicePreviewPlayer()
    private let localAnnouncer = LocalTTSPreviewPlayer()
    private var announceTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public entry points

    /// Fire-and-forget recognition from the HUD button. On a match the
    /// persona reacts in character via an injected interaction event.
    func startFromUI() {
        guard managedSession == nil else { return }
        Task { await run(source: .hudButton) }
    }

    /// Runs one recognition on behalf of the `identify_song` tool call and
    /// returns a plain-text summary the AI speaks back to the user.
    func recognizeForSkill() async -> String {
        guard managedSession == nil else {
            return "I'm already listening for the song — give me a moment."
        }
        switch await run(source: .skill) {
        case .matched(let song):
            return "The song playing is \"\(song.title)\" by \(song.artist)! "
                + "I've put Apple Music and YouTube links on screen. "
                + "Share your quick, lively reaction to the song."
        case .noMatch:
            return "I listened carefully but couldn't recognize this song. "
                + "Maybe get closer to the speaker and ask me again?"
        case .failed(let message):
            return "I couldn't listen for the song: \(message)"
        case .idle, .listening:
            return "Song recognition was cancelled."
        }
    }

    /// User dismissed the card mid-listen.
    func cancel() {
        managedSession?.cancel()
        stopAnnouncement()
        phase = .idle
    }

    /// User dismissed a finished (matched / no-match / failed) card.
    func dismiss() {
        stopAnnouncement()
        phase = .idle
    }

    // MARK: - Recognition core

    @discardableResult
    private func run(source: Source) async -> Phase {
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("Microphone access is required to identify songs.")
            return phase
        }

        phase = .listening
        nlLog("[SongID] Listening for a match (source: \(source))…", level: .info)

        // The model must never speak back to the music: gate the local
        // pipeline's VAD AND the realtime session's outgoing mic while we
        // listen, so neither engine treats the song as user speech.
        LocalLLMManager.shared.gateMicCapture(forSeconds: Self.listenTimeout + 2)
        OpenAIRealtimeManager.shared.setMicGated(true)

        // Music needs a CLEAN mic. With a voice pipeline active the capture
        // path runs voice processing (AEC + noise suppression) tuned to
        // erase exactly the non-speech content Shazam fingerprints — match
        // attempts fail with SHErrorCode 202. Suspend both pipelines' audio
        // I/O for the listen window; restored below on every exit path.
        let suspendedLocalCapture = LocalLLMManager.shared.pauseCaptureForMusicRecognition()
        OpenAIRealtimeManager.shared.suspendAudioUnit()

        // Lively touch: the avatar vibes to the music while we identify it.
        Self.startListeningAnimation()

        let session = SHManagedSession()
        managedSession = session
        timedOut = false

        // Pre-allocates the recording resources; a failure here (audio-session
        // contention with the always-running LocalLLM engine) surfaces in
        // result() below rather than as a silent stall.
        await session.prepare()

        // Give up after the timeout window — cancel() unblocks result().
        let timeout = Task {
            try? await Task.sleep(for: .seconds(Self.listenTimeout))
            guard !Task.isCancelled else { return }
            timedOut = true
            session.cancel()
        }

        let result = await session.result()
        timeout.cancel()
        managedSession = nil
        // Release the mic gate back to the normal post-speech cool-down and
        // fade the avatar back from the listening dance to the neutral idle.
        LocalLLMManager.shared.gateMicCapture(forSeconds: 0.8)
        OpenAIRealtimeManager.shared.resumeAudioUnit()
        if suspendedLocalCapture {
            LocalLLMManager.shared.resumeCaptureAfterMusicRecognition()
        }
        OpenAIRealtimeManager.shared.setMicGated(false)
        Self.stopListeningAnimation()

        // If the user cancelled while we were listening, phase is already
        // .idle — don't overwrite it with a stale result.
        guard phase == .listening else { return phase }

        switch result {
        case .match(let match):
            handleMatch(match, source: source)
        case .noMatch:
            nlLog("[SongID] No match found.", level: .info)
            phase = .noMatch
        case .error(let error, _):
            // A timeout-triggered cancel() also surfaces here — report it as
            // a plain no-match rather than a scary error.
            if timedOut || error is CancellationError {
                nlLog("[SongID] Timed out without a match.", level: .info)
                phase = .noMatch
            } else {
                let nsError = error as NSError
                let underlying = nsError.userInfo[NSUnderlyingErrorKey].map { " underlying=\($0)" } ?? ""
                nlLog(
                    "[SongID] Recognition failed: domain=\(nsError.domain) code=\(nsError.code) "
                        + "desc=\(nsError.localizedDescription)\(underlying)",
                    level: .error)
                phase = .failed(Self.friendlyMessage(for: nsError))
            }
        }
        return phase
    }

    /// Maps ShazamKit failures to actionable text. The raw domain/code is
    /// appended so device testers can diagnose on-screen — `nlLog` compiles
    /// to a no-op in Release builds, so the card is the only surface there.
    private static func friendlyMessage(for error: NSError) -> String {
        let detail = "[\(error.domain) \(error.code)]"
        guard error.domain == SHErrorDomain, let code = SHError.Code(rawValue: error.code) else {
            return "\(error.localizedDescription) \(detail)"
        }
        switch code {
        case .matchAttemptFailed, .internalError:
            // The classic symptoms of the ShazamKit app service being missing
            // from the App ID in the developer portal, or no network.
            return "Match request failed — check the internet connection and that "
                + "the ShazamKit app service is enabled for this App ID. \(detail)"
        case .invalidAudioFormat, .audioDiscontinuity, .signatureInvalid, .signatureDurationInvalid:
            // The recorder produced unusable audio — usually contention with
            // the app's own audio engine (voice processing) over the mic.
            return "Couldn't capture usable audio for matching — the mic may be "
                + "held by the voice pipeline. \(detail)"
        default:
            return "\(error.localizedDescription) \(detail)"
        }
    }

    private func handleMatch(_ match: SHMatch, source: Source) {
        guard let item = match.mediaItems.first,
            let title = item.title,
            let artist = item.artist
        else {
            phase = .noMatch
            return
        }
        let song = RecognizedSong(
            title: title,
            artist: artist,
            artworkURL: item.artworkURL,
            appleMusicURL: item.appleMusicURL
        )
        nlLog("[SongID] Matched \"\(title)\" by \(artist)", level: .info)
        phase = .matched(song)

        // Instant avatar delight while the (much slower) LLM reaction streams in.
        RealtimeChatState.shared.triggerEmotion("surprised", duration: 2.5)

        if source == .hudButton {
            announceTitle(for: song)
        }
    }

    // MARK: - Listening animation

    /// Vibe animations bundled in Resources/Animations, one picked at random
    /// per recognition. Played through the same notification channel as the
    /// photo poses (observer in VRMMetalState+Actions).
    private static let listeningAnimations = ["dancing", "enjoying_song"]

    private static func startListeningAnimation() {
        guard let name = listeningAnimations.randomElement() else { return }
        NotificationCenter.default.post(
            name: Notification.Name("VRMPlayPoseAnimation"),
            object: nil,
            userInfo: ["pose": name]
        )
    }

    private static func stopListeningAnimation() {
        NotificationCenter.default.post(
            name: Notification.Name("VRMStopPoseAnimation"), object: nil)
    }

    // MARK: - Title announcement

    /// Speaks the matched title in the persona's own voice — deterministic
    /// TTS rather than an LLM turn, so the model names the song instead of
    /// riffing on it. Both engines' mics stay gated until playback ends so
    /// the announcement can't feed back into VAD or the realtime session.
    private func announceTitle(for song: RecognizedSong) {
        let line = "This is \"\(song.title)\" by \(song.artist)."
        announceTask?.cancel()
        announceTask = Task { [weak self] in
            guard let self else { return }
            LocalLLMManager.shared.gateMicCapture(forSeconds: 30)
            OpenAIRealtimeManager.shared.setMicGated(true)
            defer {
                LocalLLMManager.shared.gateMicCapture(forSeconds: 0.8)
                OpenAIRealtimeManager.shared.setMicGated(false)
            }

            let settings = OpenAISettings.shared
            if settings.isLocalLLMEnabled {
                await self.announceLocal(line)
            } else if settings.isEnabled && settings.hasValidKey {
                await self.announceOpenAI(line)
            }
            await self.waitForAnnouncementPlayback()
        }
    }

    private func stopAnnouncement() {
        announceTask?.cancel()
        announceTask = nil
        cloudAnnouncer.stop()
        localAnnouncer.stop()
    }

    /// Playback runs on the announcer players after synthesis returns; hold
    /// the mic gates until they drain (bounded backstop for safety).
    private func waitForAnnouncementPlayback() async {
        let deadline = Date().addingTimeInterval(20)
        while cloudAnnouncer.isSpeaking || localAnnouncer.isSpeaking,
              Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private var announcePersona: String {
        let name = RealtimeChatState.shared.selectedCharacterName
        guard name.isEmpty else { return name }
        return VRMModelRegistry.shared.defaultModel?.name ?? "Ekaterina"
    }

    /// Local mode: synthesize through the persona's resolved engine, routing
    /// buffers to our own player (callback saved/restored — same pattern as
    /// TranscriptSpeechPlayer) so a live chat turn's audio isn't hijacked.
    private func announceLocal(_ text: String) async {
        let persona = announcePersona
        guard let engine = TTSEngineSelector.shared.engine(for: persona) else {
            nlLog("[SongID] No TTS engine for '\(persona)' — skipping announcement", level: .warning)
            return
        }
        let previousCallback = engine.onBufferReady
        engine.onBufferReady = { [weak localAnnouncer] buffer in
            DispatchQueue.main.async { localAnnouncer?.schedule(buffer) }
        }
        defer { engine.onBufferReady = previousCallback }
        do {
            try await engine.initialize()
            guard !Task.isCancelled else { return }
            try await engine.speak(text, persona: persona)
        } catch {
            nlLog("[SongID] Local announcement failed: \(error)", level: .warning)
        }
    }

    /// OpenAI mode: one-shot TTS with the persona's voice (the realtime
    /// session can't speak arbitrary literal text deterministically).
    private func announceOpenAI(_ text: String) async {
        let settings = OpenAISettings.shared
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else { return }
        let voice = CharacterPersona.forCharacter(named: announcePersona).voice
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let body: [String: Any] = ["model": "tts-1", "input": text, "voice": voice]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = httpBody
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                nlLog("[SongID] Announcement TTS failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)", level: .warning)
                return
            }
            guard !Task.isCancelled else { return }
            cloudAnnouncer.start(data: data)
        } catch {
            nlLog("[SongID] Announcement TTS request failed: \(error)", level: .warning)
        }
    }
}
