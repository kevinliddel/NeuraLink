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
//  Apple Music / YouTube links) → the persona reacts to the match.
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
        phase = .idle
    }

    /// User dismissed a finished (matched / no-match / failed) card.
    func dismiss() {
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

        // Keep the persona's VAD from treating the music as user speech and
        // triggering a spurious turn while we listen.
        LocalLLMManager.shared.gateMicCapture(forSeconds: Self.listenTimeout + 2)

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
        // Release the mic gate back to the normal post-speech cool-down.
        LocalLLMManager.shared.gateMicCapture(forSeconds: 0.8)

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
            injectPersonaReaction(for: song)
        }
    }

    // MARK: - Persona reaction

    /// Injects a system-style event so the active persona reacts to the song
    /// in character — the same pattern as head-pat interaction events and
    /// proactive vision updates. Skill-initiated recognitions skip this: the
    /// tool-call result already carries the reply.
    private func injectPersonaReaction(for song: RecognizedSong) {
        let event = "*The song \"\(song.title)\" by \(song.artist) is playing nearby. "
            + "Share your quick, lively in-character reaction to it*"

        let openAI = OpenAISettings.shared
        if openAI.isEnabled && openAI.hasValidKey {
            OpenAIRealtimeManager.shared.sendInteractionEvent(event)
        } else if openAI.isLocalLLMEnabled {
            // Only interject when the local pipeline is idle — never barge in
            // on an in-flight generation or TTS playback.
            let status = RealtimeChatState.shared.status
            guard status == .ready || status == .listening else {
                nlLog("[SongID] Skipping persona reaction — pipeline busy (\(status.label)).", level: .info)
                return
            }
            LocalLLMManager.shared.handleUserInput(event, logToTimeline: false)
        }
    }
}
