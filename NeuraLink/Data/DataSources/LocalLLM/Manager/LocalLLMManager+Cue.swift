//
//  LocalLLMManager+Cue.swift
//  NeuraLink
//
//  Lines the companion says on its own initiative on the local models:
//  breaking a silence, greeting the user back, reacting to a song or a head
//  pat. These used to go in as the user's message, and a 1–2B model answered
//  or read out the English instruction — spoken aloud, and shown on screen as
//  if the user had said it. A cue is an instruction (in Japanese for LLM-jp),
//  the user's transcript stays untouched, and the reply is only shown and
//  spoken once CueReplyValidator has checked it isn't the instruction coming
//  back.
//
//  Created by Dedicatus on 21/10/2026.
//

import Foundation

extension LocalLLMManager {

    /// Runs `cue` on the local model. False when the model isn't loaded or a
    /// turn is already in flight (a cue never interrupts one).
    @discardableResult
    func handleCue(_ cue: LocalCue) -> Bool {
        guard llmEngine.isLoaded, state.status == .ready || state.status == .listening else { return false }
        let config = LocalModelDownloadManager.shared.selectedConfig
        let character = state.selectedCharacterName
        let instruction = cue.instruction(
            japaneseModel: config == .llmJp3, characterName: state.characterDisplayName)

        turnStartNs = DispatchTime.now().uptimeNanoseconds
        firstTokenLatencyLogged = false
        firstAudioLatencyLogged = false
        firstTTSChunkPending = true
        replyLabelFilter = LeadingLabelFilter(names: replyLabelNames)
        activeCueInstruction = instruction
        transcriptTypewriter.reset()
        state.status = .thinking
        nlLogSensitive("[LocalLLM] Cue: \(instruction.prefix(90))…", level: .info)

        Task {
            let base = localLLMSystemPrompt(for: character)
            let messages = await LocalLLMMemoryHierarchy.shared.buildCueMessages(
                instruction: instruction, config: config, characterName: character, baseSystemPrompt: base)
            let prompt = llmEngine.applyChatTemplate(messages: messages) ?? fallbackChatPrompt(messages: messages)
            await llmEngine.generate(prompt: prompt, maxTokens: 60)
        }
        return true
    }
}
