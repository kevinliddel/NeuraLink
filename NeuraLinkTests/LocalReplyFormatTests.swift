//
//  LocalReplyFormatTests.swift
//  NeuraLinkTests
//
//  LLM-jp-3's native prompt format, the stop and speaker-label filters on a
//  streamed reply, and the check that keeps a proactive cue's instruction
//  from being spoken back.
//
//  Created by Dedicatus on 21/10/2026.
//

import Foundation
import Testing
@testable import NeuraLink

@Suite("Local reply format")
struct LocalReplyFormatTests {

    // MARK: - LLM-jp-3 format

    @Test("LLM-jp prompts use ### 指示 / ### 応答 with the persona inside the instruction")
    func llmjpFormat() {
        let prompt = LLMjpPromptFormat.render(
            [.init(role: "system", content: "私はオズ、執事です。"), .init(role: "user", content: "（日本語で回答）こんにちは")],
            addGenerationPrompt: true)
        #expect(prompt.hasPrefix(LLMjpPromptFormat.preamble))
        #expect(prompt.contains("### 指示:\n私はオズ、執事です。\n\n（日本語で回答）こんにちは"))
        #expect(prompt.hasSuffix("\n\n### 応答:\n"))
        #expect(!prompt.contains("<|start_header_id|>"))
        #expect(!prompt.contains("<s>"), "BOS comes from the tokenizer")
    }

    @Test("The JP warm-up prompt is a prefix of the real turn's prompt")
    func llmjpWarmupIsPrefix() {
        let system = LLMChatMessage(role: "system", content: "必ず日本語で返答してください。")
        let lead = LocalLLMMemoryHierarchy.jpAnswerLeadIn
        let warm = LLMjpPromptFormat.render([system, .init(role: "user", content: lead)], addGenerationPrompt: false)
        let turn = LLMjpPromptFormat.render([system, .init(role: "user", content: lead + "今日は寒いね")], addGenerationPrompt: true)
        #expect(turn.hasPrefix(warm))
    }

    // MARK: - Stop sequences

    private func stream(_ pieces: [String]) -> (text: String, stopped: Bool) {
        var filter = StopSequenceFilter()
        var out = ""
        for piece in pieces {
            out += filter.feed(piece)
            if filter.stopped { break }
        }
        out += filter.flush()
        return (out, filter.stopped)
    }

    @Test("A reply stops where the model starts the next turn, and nothing of the marker leaks")
    func stopsAtNextTurn() {
        let r = stream(["かしこまりました", "、旦那様。\n", "ユー", "ザー：", "最近のニュース"])
        #expect(r.text == "かしこまりました、旦那様。")
        #expect(r.stopped)
        let english = stream(["Of course.", "\nUs", "er: what"])
        #expect(english.text == "Of course.")
        let block = stream(["Done.", "\n\n###", " 指示:"])
        #expect(block.text == "Done.\n")
    }

    @Test("A reply that opens by quoting the user is dropped whole")
    func leadingScriptIsDropped() {
        let r = stream(["ユーザー", "：最近のニュースについて", "教えてください。"])
        #expect(r.text.isEmpty)
        #expect(r.stopped)
    }

    @Test("Ordinary text passes untouched, even when it briefly looks like a marker")
    func ordinaryTextPasses() {
        let r = stream(["ユニークな", "お茶ですね。", "Use it ", "well</", "tool>"])
        #expect(r.text == "ユニークなお茶ですね。Use it well</tool>")
        #expect(!r.stopped)
    }

    // MARK: - Speaker labels

    @Test("A leading speaker label is dropped, streamed or whole")
    func labelsAreStripped() {
        var filter = LeadingLabelFilter(names: ["Oz"])
        var out = filter.feed("O")
        out += filter.feed("z: ")
        out += filter.feed("Good evening.")
        #expect(out == "Good evening.")
        #expect(LeadingLabelFilter.strip("Oz：かしこまりました。", names: ["Oz"]) == "かしこまりました。")
        #expect(LeadingLabelFilter.strip("Ozone is nice.", names: ["Oz"]) == "Ozone is nice.")
        #expect(LeadingLabelFilter.strip("Assistant: Hi", names: []) == "Hi")
        #expect(LeadingLabelFilter.strip("オズ：かしこまりました。", names: []) == "かしこまりました。")
        #expect(LeadingLabelFilter.strip("カレーは好き？", names: []) == "カレーは好き？")
    }

    // MARK: - Cue replies

    @Test("A cue's reply that echoes or narrates its instruction is never spoken")
    func cueEchoIsRejected() {
        let jp = ProactivePresenceManager.smallTalkEventJapanese(
            name: "Oz", timeOfDay: "午後", angle: .checkIn, previousLine: nil)
        #expect(CueReplyValidator.clean("今は午後で、しばらく会話が途切れています。", instruction: jp, names: ["Oz"]) == nil)
        #expect(CueReplyValidator.clean("ユーザーが静かにしている。", instruction: jp, names: ["Oz"]) == nil)
        #expect(CueReplyValidator.clean("Oz：紅茶でもお淹れしましょうか。", instruction: jp, names: ["Oz"]) == "紅茶でもお淹れしましょうか。")
        #expect(CueReplyValidator.clean("オズ：「午後の紅茶はいかがでしょう。」", instruction: jp, names: ["Oz"]) == "午後の紅茶はいかがでしょう。")
        #expect(CueReplyValidator.clean("まだユーザー様はいらっしゃいません。", instruction: jp, names: []) == nil)
        #expect(CueReplyValidator.clean("オズのセリフ：こんにちは", instruction: jp, names: []) == nil)

        let en = ProactivePresenceManager.smallTalkEvent(timeOfDay: "afternoon", stage: "Friends", factSeed: nil)
        #expect(CueReplyValidator.clean("*The user has gone quiet for a while.*", instruction: en, names: ["Oz"]) == nil)
        #expect(CueReplyValidator.clean("Break the silence in character with one line.", instruction: en, names: ["Oz"]) == nil)
        #expect(CueReplyValidator.clean("Shall I put the kettle on, Sir?", instruction: en, names: ["Oz"]) == "Shall I put the kettle on, Sir?")
        #expect(CueReplyValidator.clean("   ", instruction: en, names: []) == nil)
    }

    @Test("Real LLM-jp cue replies: narration and labels around a quote keep only the quote")
    func narratedQuotes() {
        let names = ["Oz", "オズ"]
        let checkIn = ProactivePresenceManager.smallTalkEventJapanese(
            name: "オズ", timeOfDay: "午後", angle: .checkIn, previousLine: nil)
        #expect(CueReplyValidator.clean(
            "もちろんです。オズのセリフを書きます。\n「もう少しでお休みの時間ですね。まだお話したいことはありますか？」というような感じでいかがでしょうか。",
            instruction: checkIn, names: names) == "もう少しでお休みの時間ですね。まだお話したいことはありますか？")
        #expect(CueReplyValidator.clean(
            "オズ「お久しぶりですね、○○様。もう一度ご挨拶させていただきます。」",
            instruction: checkIn, names: names) == nil, "a placeholder name is never spoken")

        let greeting = ProactivePresenceManager.greetingEventJapanese(
            name: "オズ", opener: nil, hoursAway: 30, timeOfDay: "朝")
        #expect(CueReplyValidator.clean(
            "オズ(Oz)は貴族の家に仕える執事なので、この場合は「おはようございます。ご無事でなによりです。」と返答します。",
            instruction: greeting, names: names) == "おはようございます。ご無事でなによりです。")
        #expect(CueReplyValidator.clean(
            "オズ（Oz）は執事として迎えます。\n「おかえりなさいませ、ご主人様。最近はいかがお過ごしでしたか？",
            instruction: greeting, names: names) == "おかえりなさいませ、ご主人様。最近はいかがお過ごしでしたか？",
            "an unclosed quote at the end still counts")

        // Speech that merely contains a quote is left alone.
        #expect(CueReplyValidator.quotedLine(in: "昨日「星の王子さま」を読み返しました。", names: names)
                == "昨日「星の王子さま」を読み返しました。")
        #expect(CueReplyValidator.quotedLine(in: "オズです。「紅茶」をお持ちしました。", names: names)
                == "オズです。「紅茶」をお持ちしました。", "a short quote is a word, not the line")
    }

    @Test("Japanese cues are Japanese; an English-only cue gets a Japanese frame for LLM-jp")
    func japaneseCues() {
        let small = ProactivePresenceManager.smallTalkEventJapanese(
            name: "Oz", timeOfDay: "夕方", angle: .shareThought, previousLine: "紅茶はいかがですか。")
        #expect(small.contains("Oz") && small.contains("夕方") && small.contains("紅茶はいかがですか。"))
        #expect(!small.lowercased().contains("the user"))
        let greet = ProactivePresenceManager.greetingEventJapanese(
            name: "Oz", opener: "I saved a thought for you", hoursAway: 50, timeOfDay: "朝")
        #expect(greet.contains("2日") && !greet.contains("I saved") && greet.hasPrefix("Ozのセリフ"))
        let cue = LocalCue(english: "Announce the song.")
        #expect(cue.instruction(japaneseModel: false, characterName: "Oz") == "Announce the song.")
        #expect(cue.instruction(japaneseModel: true, characterName: "オズ").hasPrefix("オズのセリフを一つだけ書いてください。"))
        #expect(LocalCue(english: "x", japanese: "日本語").instruction(japaneseModel: true, characterName: "Oz") == "日本語")
        #expect(ProactivePresenceManager.timeOfDayJapanese(hour: 14) == "午後")
    }
}
