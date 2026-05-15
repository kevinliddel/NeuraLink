//
//  LocalLLMManager+Engine.swift
//  NeuraLink
//
//  LocalLLMEngineDelegate implementation.
//  Handles tokens as they are streamed from the local SLM.
//
//  Created by Dedicatus on 10/05/2026.
//

import Foundation

extension LocalLLMManager: LocalLLMEngineDelegate {

    func localLLM(didGenerateToken token: String) {
        if !firstTokenLatencyLogged,
            let start = turnStartNs,
            !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            firstTokenLatencyLogged = true
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            print("[LocalLLM] First token latency: \(String(format: "%.1f", elapsedMs)) ms")
        }

        Task { @MainActor in
            if state.status == .thinking {
                state.status = .speaking
            }
            state.aiTranscript += token
            state.parseAndTriggerEmotion(from: state.aiTranscript)
        }

        ttsBuffer += token

        let openBrackets  = ttsBuffer.filter { $0 == "[" }.count
        let closeBrackets = ttsBuffer.filter { $0 == "]" }.count
        let insideTag = openBrackets > closeBrackets

        if !insideTag
            && (token.contains(".") || token.contains("!") || token.contains("?")
                || token.contains("。") || token.contains(",") || token.contains("\n")
                || (ttsBuffer.count >= 32 && ttsBuffer.contains(" "))) {
            let chunkToSpeak = ttsBuffer
            ttsBuffer = ""
            speakChunk(chunkToSpeak)
        }
    }

    func localLLM(didFinishGeneration fullText: String) {
        if let start = turnStartNs {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            print("[LocalLLM] Turn total latency: \(String(format: "%.1f", elapsedMs)) ms")
        }

        // Local tool-calling: if a <tool name="...">{json}</tool> block is present,
        // execute it via the same Skill system used by OpenAI realtime.
        if let tool = LocalToolCallParser.firstToolCall(in: fullText) {
            Task { @MainActor in
                let result = await AppFunctionExecutor.shared.execute(name: tool.name, arguments: tool.arguments)
                ChatTimelineStore.logToolCall(name: tool.name, result: result)
                self.state.aiTranscript = result
                self.speakChunk(result)
                if AppFunctionExecutor.shared.pendingUIAction != nil {
                    self.schedulePendingUIActionAfterSpeech()
                }
            }
        }

        // RAG: Store the user's input and the AI's response in long-term memory
        let userText = state.userTranscript
        RAGManager.shared.store(text: userText, source: "user")
        let stripped = LocalToolCallParser.strippedText(fullText)
        if !stripped.isEmpty {
            RAGManager.shared.store(text: stripped, source: "ai")
            ChatTimelineStore.logAIMessage(stripped)
        }

        if !ttsBuffer.trimmingCharacters(in: .whitespaces).isEmpty {
            speakChunk(ttsBuffer)
            ttsBuffer = ""
        }
        Task { @MainActor in
            if pendingTTSBuffers == 0 {
                state.status = .ready
            } else {
                ttsGenerationDone = true
            }
        }
    }

    func localLLM(didFailWithError error: Error) {
        Task { @MainActor in
            state.setError(error.localizedDescription)
        }
    }
}
