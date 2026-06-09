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
        tagBuffer += token

        let (cleanText, emotions) = drainTagBuffer()

        if !firstTokenLatencyLogged,
            let start = turnStartNs,
            !cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            firstTokenLatencyLogged = true
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            nlLog("[LocalLLM] First token latency: \(String(format: "%.1f", elapsedMs)) ms", level: .info)
        }

        Task { @MainActor in
            if state.status == .thinking { state.status = .speaking }
            // Emotion tags are intercepted before reaching the transcript — trigger directly
            // so they never appear in the UI or reach TTS, matching the OpenAI set_emotion() path.
            for (emotion, duration) in emotions {
                state.triggerEmotion(emotion, duration: duration)
            }
            if !cleanText.isEmpty {
                state.aiTranscript += cleanText
            }
        }

        guard !cleanText.isEmpty else { return }

        ttsBuffer += cleanText

        // Earlier chunk emission so the user hears audio sooner — especially
        // on iPhone 11 where decode can drop to <1 tok/s under thermal stress
        // (`thermal=fair|serious|critical` in [Bench]) and VoiceVox CPU
        // synthesis runs ~13× real-time. A shorter first clause means audio
        // starts far sooner. Break chars now include Japanese clause/sentence
        // punctuation (。、！？，…) — previously JP only broke at full
        // sentences because `、` was missing and the count gate below required
        // a space, which Japanese text never has.
        let breakChars: Set<Character> = [
            ".", "!", "?", ",", "\n",        // ASCII / Latin
            "。", "、", "！", "？", "，", "…"   // Japanese (incl. clause comma 、)
        ]
        let hasBoundary = cleanText.contains { breakChars.contains($0) }
        // Count safety net for runs without punctuation. English requires a
        // space so we never split mid-word; CJK has no spaces, so allow a pure
        // count gate when the buffer contains kana/ideographs.
        let isCJK = ttsBuffer.unicodeScalars.contains { s in
            (0x3040...0x30FF).contains(s.value)     // Hiragana + Katakana
                || (0x4E00...0x9FFF).contains(s.value)  // CJK Unified Ideographs
        }
        let countGate = ttsBuffer.count >= 20 && (ttsBuffer.contains(" ") || isCJK)
        if hasBoundary || countGate {
            let chunkToSpeak = ttsBuffer
            ttsBuffer = ""
            speakChunk(chunkToSpeak)
        }
    }

    // Drains tagBuffer: returns (cleanText, [(emotion, duration)]).
    // Emotion tags are extracted and returned; all other text is returned as cleanText.
    // Leaves any partial open tag (no closing ']' yet) in tagBuffer for the next token.
    private func drainTagBuffer() -> (String, [(String, Float)]) {
        var clean = ""
        var emotions: [(String, Float)] = []

        while !tagBuffer.isEmpty {
            guard let openIdx = tagBuffer.firstIndex(of: "[") else {
                clean += tagBuffer
                tagBuffer = ""
                break
            }
            // Flush text that precedes the '['
            clean += String(tagBuffer[..<openIdx])
            tagBuffer = String(tagBuffer[openIdx...])

            guard let closeIdx = tagBuffer.firstIndex(of: "]") else {
                // No closing bracket yet — keep buffering if short enough for a tag
                if tagBuffer.count > 20 {
                    clean += tagBuffer
                    tagBuffer = ""
                }
                break
            }

            let candidate = String(tagBuffer[...closeIdx])
            tagBuffer = String(tagBuffer[tagBuffer.index(after: closeIdx)...])

            if let (emotion, duration) = matchEmotionTag(candidate) {
                emotions.append((emotion, duration))
            } else {
                clean += candidate
            }
        }
        return (clean, emotions)
    }

    private func matchEmotionTag(_ s: String) -> (String, Float)? {
        let pattern = #"(?i)^\[(happy|angry|sad|relaxed|surprised|shocked|shy|embarrassed|bored|confused|wink|neutral):(\d+(?:\.\d+)?)\]$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: s, range: range),
              m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: s),
              let r2 = Range(m.range(at: 2), in: s),
              let duration = Float(s[r2])
        else { return nil }
        return (String(s[r1]).lowercased(), duration)
    }

    func localLLM(didFinishGeneration fullText: String) {
        if let start = turnStartNs {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            nlLog("[LocalLLM] Turn total latency: \(String(format: "%.1f", elapsedMs)) ms", level: .info)
        }

        // Full final response at debug level — useful for inspecting what the
        // model actually produced (including tool-call blocks and emotion
        // tags before LocalToolCallParser / drainTagBuffer strip them out).
        nlLog("[LocalLLM] Full AI response: \(fullText)", level: .debug)

        // Local tool-calling is intentionally limited to `remember_fact` only.
        // All other iOS-action tools were dropped for local SLMs (shorter
        // prompt = faster cold-start prefill, and 1–2B models emit unreliable
        // tool JSON). Any stray non-emotion tool the model still produces is
        // ignored here and stripped from the transcript by `strippedText`
        // below. Emotion stays separate ([emotion:n] tags via tagBuffer).
        if let tool = LocalToolCallParser.firstToolCall(in: fullText),
           tool.name == AppFunctionTool.rememberFact {
            nlLog(
                "֎ [FunctionCall] LocalLLM emitted <tool name=\"\(tool.name)\"> with args \(tool.arguments)",
                level: .info
            )
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

        // RAG: Store in long-term memory — skip for Japanese model because English user
        // queries mixed with Japanese AI responses produce low-quality embeddings that
        // degrade future RAG retrieval across all models sharing the same memory store.
        let userText = state.userTranscript
        let isJapaneseLlama = LocalModelDownloadManager.shared.selectedConfig == .japaneseGemma2b
        if !isJapaneseLlama {
            RAGManager.shared.store(text: userText, source: "user")
        }
        let stripped = LocalToolCallParser.strippedText(fullText)
        if !stripped.isEmpty {
            if !isJapaneseLlama {
                RAGManager.shared.store(text: stripped, source: "ai")
            }
            ChatTimelineStore.logAIMessage(stripped)
        }

        // Flush any partial tag buffer (e.g. generation stopped mid-tag)
        if !tagBuffer.isEmpty {
            let (leftover, emotions) = drainTagBuffer()
            let remaining = leftover + tagBuffer  // tagBuffer holds unresolvable partial '[...'
            tagBuffer = ""
            if !remaining.isEmpty {
                ttsBuffer += remaining
                Task { @MainActor in
                    state.aiTranscript += remaining
                }
            }
            Task { @MainActor in
                for (emotion, duration) in emotions {
                    state.triggerEmotion(emotion, duration: duration)
                }
            }
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

        // Memory hierarchy: after each user-facing turn, see if any chat
        // events have aged out of the verbatim window. If so, kick off
        // background fact extraction so the next prompt's Tier 3 surfaces
        // them via RAG. No-ops when there's nothing new to compact or a
        // previous compaction is still running.
        maybeRunCompaction()
    }

    func localLLM(didFailWithError error: Error) {
        Task { @MainActor in
            state.setError(error.localizedDescription)
        }
    }
}
