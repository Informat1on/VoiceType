// WhisperTokenizer.swift — VoiceType
//
// Exact re-implementation of whisper.cpp's `tokenize()` (src/whisper.cpp:3272,
// SwiftWhisper fork, v1.9.1). Needed so the "Custom vocabulary" field in
// Settings > Advanced can show the user precisely how many tokens their
// initial_prompt will cost — whisper truncates that prompt silently, and a
// guess that's even one token off is worse than no counter at all.
//
// whisper's tokenizer is NOT BPE with merge ranks. It is:
//   1. split the input into "words" with a fixed regex, and
//   2. for each word, greedily match the longest known byte-string prefix
//      against a flat vocabulary, repeating from where the match left off.
//
// Two traps that make a naive Swift port diverge from the original:
//
// - `std::regex` runs in the C locale, so `[[:alpha:]]`/`[[:digit:]]` are
//   ASCII-only — Cyrillic (and everything else non-ASCII) falls into the
//   catch-all `[^\s[:alpha:][:digit:]]+` bucket, NOT the alpha bucket. Using
//   a Unicode-aware character class here would merge "Ёлкаabc" into one word
//   instead of splitting it at the script boundary the way whisper.cpp does.
//   The pattern below is the literal-ASCII-range translation of whisper.cpp's
//   pattern, verified 613/613 against a Python prototype run against real
//   whisper_tokenize output.
// - Matching happens on UTF-8 BYTES, not `Character`s. The vocabulary
//   contains raw byte strings that are not valid standalone UTF-8 on their
//   own (e.g. a lone continuation byte as its own single-byte token), so the
//   dictionary key has to be `[UInt8]`, never `String`.
import Foundation

final class WhisperTokenizer {

    static let shared = WhisperTokenizer()

    /// No entry in the shipped vocabulary is longer than this many bytes.
    /// Bounding the inner longest-match loop to this window (instead of the
    /// full remaining word length) turns the search from quadratic to linear
    /// in word length without changing a single result — no substring longer
    /// than this could ever be found in the dictionary anyway.
    private static let maxTokenBytes = 33

    /// Размер multilingual-словаря whisper (`whisper_n_vocab` на
    /// `ggml-large-v3-turbo-q5_0.bin`, v1.9.1). Ресурс с другим числом строк —
    /// не тот словарь, и доверять ему нельзя.
    private static let expectedVocabularySize = 51_866

    // whisper.cpp:3270 — translated to Swift/ICU's explicit ASCII ranges (see
    // header comment for why this must stay ASCII-only, not \p{L}/\p{N}).
    private static let wordPattern: NSRegularExpression = {
        // ⚠️ \s и \S использовать НЕЛЬЗЯ: в ICU они Unicode-aware и включают
        // NBSP, thin space и прочие пробелы категории Zs, а std::regex в
        // локали «C» считает пробельными только шесть ASCII-символов. Из-за
        // этого строка «a\u{00A0}b» разбивалась бы иначе, чем в whisper.cpp, и
        // «точный» счётчик молча врал бы. Найдено код-ревью, подтверждено
        // сверкой с настоящим whisper_tokenize.
        let ws = #"[ \t\n\x0B\f\r]"#
        let nonWs = #"[^ \t\n\x0B\f\r]"#
        let pattern = #"'s|'t|'re|'ve|'m|'ll|'d| ?[A-Za-z]+| ?[0-9]+| ?[^ \t\n\x0B\f\rA-Za-z0-9]+|"#
            + "\(ws)+(?!\(nonWs))|\(ws)+"
        // Pattern is a compile-time literal, verified by the golden fixture test.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Guards `vocabulary`/`loadAttempted`. The dictionary is built lazily
    /// (parsing the 680 KB resource costs real time and Settings is opened
    /// rarely — paying for it at app launch would be pure waste), and the
    /// caller of `count`/`tokenize`/`isReady` is not guaranteed to be main.
    private let lock = NSLock()
    private var vocabulary: [[UInt8]: Int]?
    private var loadAttempted = false

    private init() {}

    /// Whether the vocabulary resource was found and parsed. `false` means
    /// `count` is returning a conservative estimate, not an exact figure.
    var isReady: Bool {
        resolvedVocabulary() != nil
    }

    /// Exact number of tokens whisper would produce for `text`, or — if the
    /// vocabulary failed to load — a same-or-higher estimate (UTF-8 byte
    /// count: no whisper token is ever shorter than one byte, so this can
    /// never undercount).
    func count(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        guard let vocab = resolvedVocabulary() else { return text.utf8.count }
        return Self.tokenIds(for: text, vocabulary: vocab).count
    }

    /// Exact token id sequence, in order. Empty (not an estimate) when the
    /// vocabulary isn't loaded — callers that need a placeholder in that case
    /// should check `isReady` first, same as `count` does internally.
    func tokenize(_ text: String) -> [Int] {
        guard !text.isEmpty, let vocab = resolvedVocabulary() else { return [] }
        return Self.tokenIds(for: text, vocabulary: vocab)
    }

    // MARK: - Lazy load

    private func resolvedVocabulary() -> [[UInt8]: Int]? {
        lock.lock()
        defer { lock.unlock() }
        if !loadAttempted {
            loadAttempted = true
            vocabulary = Self.loadVocabulary()
        }
        return vocabulary
    }

    /// Parses `whisper-vocab-multilingual.txt`: one line per token id (line
    /// number == id), line content is the token's bytes hex-encoded.
    ///
    /// Two things the resource's own description undersells:
    /// - It is NOT free of empty lines. Ids 188 and 50256 are both empty
    ///   strings (the byte-fallback NUL-byte slot and the <|endoftext|>
    ///   control token respectively, going by their position in the vocab).
    ///   This is exactly the "one byte-string shared by two ids" duplicate
    ///   case below — last (larger) id wins, and since the longest-match loop
    ///   never queries a zero-length substring, the duplicate is inert for
    ///   `tokenize()` either way. It only matters here because splitting on
    ///   "\n" with Swift's default `omittingEmptySubsequences: true` would
    ///   silently drop both lines and shift every id from 188 onward by one —
    ///   corrupting the entire back half of the vocabulary. Must split with
    ///   `omittingEmptySubsequences: false`.
    /// - `token_to_id[word] = i` in whisper.cpp is a plain assignment inside
    ///   an ascending-id loop, so when two ids decode to the same byte string
    ///   the larger id overwrites the smaller — replicated here by just
    ///   letting the later (higher-id) dictionary write win, same order.
    private static func loadVocabulary() -> [[UInt8]: Int]? {
        guard let url = Bundle.module.url(forResource: "whisper-vocab-multilingual", withExtension: "txt"),
              var content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        // Strip exactly one trailing newline before splitting, so the split
        // doesn't manufacture a spurious extra empty "line" past the real
        // last id — see the empty-line note above for why the split itself
        // must not drop empty subsequences.
        if content.hasSuffix("\n") {
            content.removeLast()
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        // Число строк — часть контракта ресурса, а не косметика. Обрезанный или
        // подменённый файл с корректным hex прошёл бы посимвольную проверку
        // ниже и дал бы `isReady == true` при неполном словаре: неизвестные
        // байты молча пропускались бы, и счётчик ЗАНИЖАЛ бы длину промпта —
        // ровно та ошибка, ради предотвращения которой он написан. Лучше честно
        // уйти на консервативную оценку. Замечание код-ревью.
        guard lines.count == expectedVocabularySize else {
            return nil
        }

        var map: [[UInt8]: Int] = [:]
        map.reserveCapacity(lines.count)
        for (id, line) in lines.enumerated() {
            guard let bytes = hexDecode(line) else {
                return nil // Malformed resource — fail closed to the estimate path, not a partial table.
            }
            map[bytes] = id
        }
        return map
    }

    private static func hexDecode(_ hex: Substring) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    // MARK: - Algorithm (whisper.cpp:3272)

    private static func tokenIds(for text: String, vocabulary: [[UInt8]: Int]) -> [Int] {
        var tokens: [Int] = []
        for word in splitWords(text) {
            guard !word.isEmpty else { continue }
            let bytes = Array(word.utf8)
            let n = bytes.count
            var i = 0
            while i < n {
                var j = min(n, i + maxTokenBytes)
                var found = false
                while j > i {
                    if let id = vocabulary[Array(bytes[i..<j])] {
                        tokens.append(id)
                        i = j
                        found = true
                        break
                    }
                    j -= 1
                }
                if !found {
                    // whisper.cpp: WHISPER_LOG_ERROR("unknown token\n"); ++i;
                    // Should not happen for the shipped multilingual vocab
                    // (single bytes are covered), but replicate the fallback
                    // exactly rather than throwing.
                    i += 1
                }
            }
        }
        return tokens
    }

    /// whisper.cpp's `while (regex_search(str, m, re)) { words.push_back(m[0]); str = m.suffix(); }`
    /// loop is exactly "successive non-overlapping matches left to right" —
    /// the pattern has no capture groups, so `for (auto x : m)` only ever
    /// yields the whole match. `NSRegularExpression.matches` gives the same
    /// sequence directly.
    private static func splitWords(_ text: String) -> [String] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return wordPattern.matches(in: text, range: range).map { ns.substring(with: $0.range) }
    }
}
