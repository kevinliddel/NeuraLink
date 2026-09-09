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

    /// One capture attempt's outcome — shared by the one-shot flow and the
    /// co-listening session loop (+Session extension).
    enum ListenOutcome: Equatable {
        case matched(RecognizedSong)
        case noMatch
        case failed(String)
    }

    /// Where the request came from. A skill-initiated recognition returns its
    /// summary through the tool-call result (the AI speaks it), so only
    /// HUD-initiated ones inject a separate reaction event into the chat.
    private enum Source { case hudButton, skill }

    /// Internal (not private) so the +Session extension can cancel it.
    @ObservationIgnored var managedSession: SHManagedSession?

    /// Set by the watchdog before it cancels the session, so the resulting
    /// `.error` is reported as a plain no-match instead of a failure.
    private var timedOut = false

    /// Max listen window before giving up. Shazam usually matches within
    /// ~4–10 s of clean audio; anything longer means it won't match at all.
    static let listenTimeout: TimeInterval = 18

    // MARK: - Co-listening session state (driven by the +Session extension;
    // treat as read-only everywhere else)

    /// True while a "listening together" session runs (Phase 4a). Observable —
    /// the overlay renders session-flavored text and the close button ends
    /// the whole session.
    var isSessionActive = false
    @ObservationIgnored var sessionTask: Task<Void, Never>?
    @ObservationIgnored var sessionStartedAt: Date?
    @ObservationIgnored var lastTrackKey = ""
    @ObservationIgnored var lastCommentAt = Date.distantPast
    @ObservationIgnored var sessionFailureStreak = 0
    @ObservationIgnored var sessionObservers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Public entry points

    /// Fire-and-forget recognition from the HUD button. On a match the
    /// persona reacts in character via an injected interaction event.
    func startFromUI() {
        guard managedSession == nil, !isSessionActive else { return }
        Task { await run(source: .hudButton) }
    }

    /// Runs one recognition on behalf of the `identify_song` tool call and
    /// returns a plain-text summary the AI speaks back to the user.
    func recognizeForSkill() async -> String {
        guard !isSessionActive else {
            return "We're already in a listening session — I'm following the music."
        }
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

    /// User dismissed the card mid-listen. During a co-listening session
    /// this ends the whole session.
    func cancel() {
        if isSessionActive {
            stopSession(reason: "user")
            return
        }
        managedSession?.cancel()
        phase = .idle
    }

    /// User dismissed a finished (matched / no-match / failed) card.
    func dismiss() {
        if isSessionActive {
            stopSession(reason: "user")
            return
        }
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

        let suspendedLocalCapture = beginCaptureWindow()
        let outcome = await listenOnce()
        endCaptureWindow(suspendedLocalCapture: suspendedLocalCapture)

        // If the user cancelled while we were listening, phase is already
        // .idle — don't overwrite it with a stale result.
        guard phase == .listening else { return phase }

        switch outcome {
        case .matched(let song):
            presentMatch(song)
            if source == .hudButton {
                announceTitle(for: song)
            }
        case .noMatch:
            phase = .noMatch
        case .failed(let message):
            phase = .failed(message)
        }
        return phase
    }

    // MARK: - Capture window (shared with the +Session co-listening loop)

    /// Prepares both voice pipelines for a clean music capture. Returns
    /// whether the local capture path was suspended (pass it back to
    /// `endCaptureWindow`).
    func beginCaptureWindow() -> Bool {
        // The model must never speak back to the music: gate the local
        // pipeline's VAD AND the realtime session's outgoing mic while we
        // listen, so neither engine treats the song as user speech.
        LocalLLMManager.shared.gateMicCapture(forSeconds: Self.listenTimeout + 2)
        OpenAIRealtimeManager.shared.setMicGated(true, reason: .songRecognition)
        // A mid-sentence assistant reply must not resume and talk over (or
        // after) the music — cancel it now. The only assistant output around
        // a recognition is the title announcement afterwards.
        OpenAIRealtimeManager.shared.cancelActiveResponse()

        // Music needs a CLEAN mic. With a voice pipeline active the capture
        // path runs voice processing (AEC + noise suppression) tuned to
        // erase exactly the non-speech content Shazam fingerprints — match
        // attempts fail with SHErrorCode 202. Suspend both pipelines' audio
        // I/O for the listen window; restored in `endCaptureWindow` on every
        // exit path.
        let suspendedLocalCapture = LocalLLMManager.shared.pauseCaptureForMusicRecognition()
        OpenAIRealtimeManager.shared.suspendAudioUnit()
        return suspendedLocalCapture
    }

    /// Restores both voice pipelines after a capture window.
    func endCaptureWindow(suspendedLocalCapture: Bool) {
        // Release the mic gate back to the normal post-speech cool-down.
        LocalLLMManager.shared.gateMicCapture(forSeconds: 0.8)
        OpenAIRealtimeManager.shared.resumeAudioUnit()
        if suspendedLocalCapture {
            LocalLLMManager.shared.resumeCaptureAfterMusicRecognition()
        }
        OpenAIRealtimeManager.shared.setMicGated(false, reason: .songRecognition)
        // The capture window's mode churn can silently re-route output to
        // the receiver — put it back on the speaker so the announcement
        // plays at normal volume.
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
    }

    /// One ShazamKit capture attempt (≤ `listenTimeout`). Must run inside an
    /// open capture window.
    func listenOnce() async -> ListenOutcome {
        let session = SHManagedSession()
        managedSession = session
        timedOut = false

        // Pre-allocates the recording resources; a failure here (audio-session
        // contention with the always-running LocalLLM engine) surfaces in
        // the results below rather than as a silent stall.
        await session.prepare()

        // Give up after the timeout window — cancel() ends the result stream.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(Self.listenTimeout))
            guard !Task.isCancelled else { return }
            timedOut = true
            session.cancel()
        }

        // `result()` would be a SINGLE match attempt (only the first few
        // seconds of audio) — one early miss and we'd report no-match even
        // though more listening would land it. Iterate successive attempts
        // until a match arrives or the watchdog cancels the session.
        var result: SHSession.Result?
        for await attempt in session.results {
            if case .noMatch = attempt {
                nlLog("[SongID] Attempt missed — still listening…", level: .info)
                result = attempt
                continue
            }
            result = attempt
            break
        }
        timeout.cancel()
        managedSession = nil

        switch result {
        case .match(let match):
            guard let song = Self.song(from: match) else { return .noMatch }
            nlLog("[SongID] Matched \"\(song.title)\" by \(song.artist)", level: .info)
            return .matched(song)
        case .noMatch, nil:
            nlLog(timedOut ? "[SongID] Timed out without a match." : "[SongID] No match found.", level: .info)
            return .noMatch
        case .error(let error, _):
            // A timeout-triggered cancel() also surfaces here — report it as
            // a plain no-match rather than a scary error.
            if timedOut || error is CancellationError {
                nlLog("[SongID] Timed out without a match.", level: .info)
                return .noMatch
            }
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey].map { " underlying=\($0)" } ?? ""
            nlLog(
                "[SongID] Recognition failed: domain=\(nsError.domain) code=\(nsError.code) "
                    + "desc=\(nsError.localizedDescription)\(underlying)",
                level: .error)
            return .failed(Self.friendlyMessage(for: nsError))
        }
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

    static func song(from match: SHMatch) -> RecognizedSong? {
        guard let item = match.mediaItems.first,
            let title = item.title,
            let artist = item.artist
        else { return nil }
        return RecognizedSong(
            title: title,
            artist: artist,
            artworkURL: item.artworkURL,
            appleMusicURL: item.appleMusicURL
        )
    }

    /// Shows a match on the capsule with the instant avatar delight (the
    /// slower LLM reaction/announcement streams in after).
    func presentMatch(_ song: RecognizedSong, emotion: String = "surprised") {
        phase = .matched(song)
        RealtimeChatState.shared.triggerEmotion(emotion, duration: 2.5)
    }

    /// Setter seam for the +Session extension (`phase` stays `private(set)`
    /// so views can't mutate it).
    func setPhase(_ newPhase: Phase) {
        phase = newPhase
    }

    // MARK: - Title announcement

    /// Asks the active model to announce the matched title IN CHARACTER —
    /// generated, not templated, so each persona keeps its own style and
    /// language (Ekaterina announces in Japanese). OpenAI: the realtime
    /// session generates, speaks, and its transcript handler logs history.
    /// Local: a focused generation turn through the normal pipeline, only
    /// when it isn't mid-turn.
    private func announceTitle(for song: RecognizedSong) {
        let event = "*You just identified a song playing nearby: "
            + "\"\(song.title)\" by \(song.artist). "
            + "Tell the user its title and artist in ONE short, excited, playful sentence, "
            + "in your usual speaking style and language. "
            + "Do not add anything beyond announcing the song.*"

        let settings = OpenAISettings.shared
        if settings.isLocalLLMEnabled {
            // Never barge in on an in-flight generation or TTS playback.
            let status = RealtimeChatState.shared.status
            guard status == .ready || status == .listening else {
                nlLog("[SongID] Skipping announcement — pipeline busy (\(status.label)).", level: .info)
                return
            }
            LocalLLMManager.shared.handleUserInput(event, logToTimeline: false)
        } else if settings.isEnabled && settings.hasValidKey {
            OpenAIRealtimeManager.shared.sendInteractionEvent(event)
        }
    }
}
