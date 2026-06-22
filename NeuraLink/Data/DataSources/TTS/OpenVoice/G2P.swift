//
//  G2P.swift
//  NeuraLink
//
//  English grapheme-to-phoneme for the OpenVoice TTS (non-JP), mirroring melo's
//  front-end: text_normalize → BERT BasicTokenizer word split → CMUdict lexicon
//  lookup (refine_syllables, baked offline) → post_replace_ph → pad "_" →
//  cleaned_text_to_sequence (ids, tone+tone_start, lang_id) → intersperse(0).
//  OOV words (not in the 129k-word lexicon) fall back to per-char UNK for now
//  (melo uses an LSTM; baking more words or porting it is a later improvement).
//
//  For intonation we also emit the BERT alignment melo uses: each BasicToken is
//  WordPiece-tokenized (bert-base-uncased vocab) to get its sub-token ids and
//  count, then distribute_phone spreads the token's phones across its sub-tokens
//  → word2ph (doubled for the interspersed blanks, +1 on the leading pad). The
//  bridge runs BERT over input_ids and repeats each token's hidden vector
//  word2ph[i] times to build ja_bert[768, T]. Assets: g2p_symbols.txt,
//  g2p_lexicon.txt, g2p_meta.json, bert_vocab.txt (bundled).
//

import Foundation

final class G2P {

    struct Encoded {
        let phones: [Int64]
        let tones: [Int64]
        let langs: [Int64]
        let word2ph: [Int32]    // one entry per input id, doubled; sums to phones.count
        let inputIds: [Int64]   // BERT WordPiece ids: [CLS] … [SEP] (empty if no vocab)
    }

    private let symbols: [String]
    private let symbolToId: [String: Int32]
    private let lexicon: [String: ([String], [Int32])]
    private let toneStart: Int32
    private let langId: Int32
    private let repMap: [String: String]
    private let unkId: Int32

    // BERT WordPiece vocab (empty → intonation disabled, ja_bert stays zero).
    private let bertVocab: [String: Int32]
    private let clsId: Int64
    private let sepId: Int64
    private let unkBertId: Int32

    init?(symbolsURL: URL, lexiconURL: URL, metaURL: URL, bertVocabURL: URL? = nil) {
        guard let symText = try? String(contentsOf: symbolsURL, encoding: .utf8),
              let lexText = try? String(contentsOf: lexiconURL, encoding: .utf8),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] else { return nil }

        symbols = symText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var s2i: [String: Int32] = [:]
        for (i, s) in symbols.enumerated() where !s.isEmpty { s2i[s] = Int32(i) }
        symbolToId = s2i
        unkId = s2i["UNK"] ?? 0

        var lex: [String: ([String], [Int32])] = [:]
        lex.reserveCapacity(130_000)
        for line in lexText.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let phones = parts[1].split(separator: " ").map(String.init)
            let tones = parts[2].split(separator: " ").compactMap { Int32($0) }
            lex[String(parts[0])] = (phones, tones)
        }
        lexicon = lex
        toneStart = Int32(meta["en_tone_start"] as? Int ?? 7)
        langId = Int32(meta["en_lang_id"] as? Int ?? 2)
        repMap = (meta["rep_map"] as? [String: String]) ?? [:]

        var vocab: [String: Int32] = [:]
        if let url = bertVocabURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            vocab.reserveCapacity(31_000)
            for (i, tok) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if !tok.isEmpty { vocab[String(tok)] = Int32(i) }
            }
        }
        bertVocab = vocab
        clsId = Int64(vocab["[CLS]"] ?? 101)
        sepId = Int64(vocab["[SEP]"] ?? 102)
        unkBertId = vocab["[UNK]"] ?? 100
    }

    convenience init?() {
        guard let s = Bundle.main.url(forResource: "g2p_symbols", withExtension: "txt"),
              let l = Bundle.main.url(forResource: "g2p_lexicon", withExtension: "txt"),
              let m = Bundle.main.url(forResource: "g2p_meta", withExtension: "json") else { return nil }
        let b = Bundle.main.url(forResource: "bert_vocab", withExtension: "txt")
        self.init(symbolsURL: s, lexiconURL: l, metaURL: m, bertVocabURL: b)
    }

    /// True once the BERT WordPiece vocab loaded (gates the intonation path).
    var hasBert: Bool { !bertVocab.isEmpty }

    /// text → phones/tones/langs (matching melo) + the BERT alignment (word2ph,
    /// input_ids) needed to build ja_bert. input_ids is empty when no vocab.
    func encode(_ text: String) -> Encoded {
        var phones: [String] = []
        var tones: [Int32] = []
        var word2ph: [Int32] = []
        var subIds: [Int64] = []

        for token in tokenize(normalize(text)) {
            let phoneLen: Int
            if let (p, t) = lexicon[token] {
                phones += p
                tones += t
                phoneLen = p.count
            } else {
                for ch in token {  // punctuation / OOV → per-char (post_replace maps it)
                    phones.append(String(ch))
                    tones.append(0)
                }
                phoneLen = token.count
            }
            if hasBert {
                let pieces = wordpiece(token)
                word2ph += distributePhone(phoneLen, max(pieces.count, 1))
                subIds += pieces.map(Int64.init)
            }
        }
        phones = phones.map(postReplace)
        phones = ["_"] + phones + ["_"]
        tones = [0] + tones + [0]

        let phoneIds = phones.map { symbolToId[$0] ?? unkId }
        let toneIds = tones.map { $0 + toneStart }
        let langIds = [Int32](repeating: langId, count: phoneIds.count)

        var ids: [Int64] = []
        if hasBert {
            word2ph = [1] + word2ph + [1]          // pad aligns to [CLS] / [SEP]
            word2ph = word2ph.map { $0 * 2 }        // add_blank doubling
            word2ph[0] += 1                         // leading interspersed blank
            ids = [clsId] + subIds + [sepId]
        }
        return Encoded(phones: intersperse(phoneIds), tones: intersperse(toneIds),
                       langs: intersperse(langIds), word2ph: word2ph, inputIds: ids)
    }

    // MARK: - Steps

    private func normalize(_ text: String) -> String {
        // melo: lower → expand_time → normalize_numbers → expand_abbreviations.
        // MVP ports lowercase only; number/time/abbrev expansion is a TODO (the
        // validation refs contain none). Digits left as-is for now.
        text.lowercased()
    }

    /// BERT BasicTokenizer: strip accents, split on whitespace, split each
    /// punctuation char into its own token.
    private func tokenize(_ text: String) -> [String] {
        let cleaned = text.folding(options: .diacriticInsensitive, locale: nil)
        var tokens: [String] = []
        var buf = ""
        for ch in cleaned {
            if ch == " " || ch.isWhitespace {
                if !buf.isEmpty { tokens.append(buf); buf = "" }
            } else if isPunctuation(ch) {
                if !buf.isEmpty { tokens.append(buf); buf = "" }
                tokens.append(String(ch))
            } else {
                buf.append(ch)
            }
        }
        if !buf.isEmpty { tokens.append(buf) }
        return tokens
    }

    private func isPunctuation(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let u = ch.unicodeScalars.first else {
            return ch.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
            }
        }
        let v = u.value
        if (v >= 33 && v <= 47) || (v >= 58 && v <= 64) || (v >= 91 && v <= 96) || (v >= 123 && v <= 126) {
            return true  // BERT treats all ASCII punctuation ranges as punctuation
        }
        return CharacterSet.punctuationCharacters.contains(u) || CharacterSet.symbols.contains(u)
    }

    /// HF WordPiece: greedy longest-match against the vocab, `##` on
    /// continuations; if any piece fails the whole token becomes a single [UNK].
    private func wordpiece(_ token: String) -> [Int32] {
        let chars = Array(token)
        if chars.count > 100 { return [unkBertId] }
        var ids: [Int32] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var matched: Int32?
            while start < end {
                let piece = (start > 0 ? "##" : "") + String(chars[start..<end])
                if let id = bertVocab[piece] { matched = id; break }
                end -= 1
            }
            guard let id = matched else { return [unkBertId] }
            ids.append(id)
            start = end
        }
        return ids
    }

    /// melo distribute_phone: hand each phone to the currently least-loaded
    /// sub-token (leftmost on tie). Yields 0 for sub-tokens beyond the phone count.
    private func distributePhone(_ nPhone: Int, _ nWord: Int) -> [Int32] {
        var per = [Int32](repeating: 0, count: nWord)
        for _ in 0..<nPhone {
            var minIdx = 0
            for i in 1..<nWord where per[i] < per[minIdx] { minIdx = i }
            per[minIdx] += 1
        }
        return per
    }

    private func postReplace(_ ph: String) -> String {
        let mapped = repMap[ph] ?? ph
        return symbolToId[mapped] != nil ? mapped : "UNK"
    }

    private func intersperse(_ values: [Int32]) -> [Int64] {
        var result = [Int64](repeating: 0, count: values.count * 2 + 1)
        for (i, v) in values.enumerated() { result[i * 2 + 1] = Int64(v) }
        return result
    }
}
