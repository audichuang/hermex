import Foundation

// The GPT-Live (`voice.voice_chat_mode: gpt-live`) data-channel contract and the text
// shaping around it (#1091), ported from Hermes Desktop's `voice-live.ts` and
// `use-voice-live-conversation.ts`. Pure values only: the WebRTC transport carries the
// events, the call controller decides when to send them.

enum VoiceLiveSpeaker: Equatable, Sendable {
    case user, assistant
}

/// One transcript delta from the `oai-events` channel, timed in the vendor's milliseconds.
struct VoiceLiveTranscriptFragment: Equatable, Sendable {
    let speaker: VoiceLiveSpeaker
    let text: String
    let startMs: Double
    let endMs: Double
}

/// The server events a call reacts to. Anything else on the channel is ignored.
enum VoiceLiveServerEvent: Equatable, Sendable {
    case started(sessionID: String?)
    case transcript(VoiceLiveTranscriptFragment)
    /// The voice model asked Hermes for help. The event carries no text: the request is
    /// the recent transcript (`VoiceLiveTranscript.contextWindow`).
    case delegation(id: String)
    /// A vendor error that leaves the session up. `message` is the vendor's own text.
    case error(message: String?)
    case closed(reason: String, usageSeconds: Double?)

    /// Decodes one data-channel message; nil for malformed JSON, unknown types, a
    /// delegation without an id, and the `context_injection_incomplete` error that late
    /// appends after our own close produce.
    static func decode(_ data: Data) -> VoiceLiveServerEvent? {
        guard let event = try? JSONDecoder().decode(BotJSON.self, from: data) else { return nil }
        switch event["type"].text {
        case "session.started":
            return .started(sessionID: event["session"]["id"].text)
        case let type? where type == "session.input_transcript.delta" || type == "session.output_transcript.delta":
            return .transcript(VoiceLiveTranscriptFragment(
                speaker: type == "session.input_transcript.delta" ? .user : .assistant,
                text: event["delta"].text ?? "",
                startMs: event["start_ms"].number ?? 0,
                endMs: event["end_ms"].number ?? 0
            ))
        case "session.delegation.created":
            guard let id = event["delegation"]["id"].text, !id.isEmpty else { return nil }
            return .delegation(id: id)
        case "error":
            if event["error"]["code"].text == "context_injection_incomplete" { return nil }
            return .error(message: event["error"]["message"].text)
        case "session.closed":
            return .closed(reason: event["reason"].text ?? "closed", usageSeconds: event["usage"]["seconds"].number)
        default:
            return nil
        }
    }
}

/// Builds the client events a call sends, numbering them from one counter like Desktop:
/// appends carry `delegation_id` (JSON null when none), mute toggles only an `event_id`,
/// and `session.close` is bare.
struct VoiceLiveClientEvents {
    private var counter = 0

    static let close: BotJSON = .object(["type": .string("session.close")])

    /// A result the voice says aloud (paraphrased), split into append-sized chunks.
    mutating func commentary(_ text: String, delegationID: String?) -> [BotJSON] {
        VoiceLiveProtocol.commentaryChunks(text).map { append("session.commentary.append", prefix: "say", content: $0, delegationID: delegationID) }
    }

    /// Quiet progress for the voice ("Hermes is working: terminal. Not done yet.").
    mutating func thinking(_ text: String, delegationID: String?) -> BotJSON? {
        let content = VoiceLiveProtocol.prefixFittingAppend(VoiceLiveProtocol.collapsedWhitespace(text))
        guard !content.isEmpty else { return nil }
        return append("session.thinking.append", prefix: "think", content: content, delegationID: delegationID)
    }

    mutating func inputAudio(muted: Bool) -> BotJSON {
        .object([
            "type": .string(muted ? "session.input_audio.mute" : "session.input_audio.unmute"),
            "event_id": .string(nextID(muted ? "mute" : "unmute")),
        ])
    }

    private mutating func append(_ type: String, prefix: String, content: String, delegationID: String?) -> BotJSON {
        .object([
            "type": .string(type),
            "event_id": .string(nextID(prefix)),
            "delegation_id": delegationID.map(BotJSON.string) ?? .null,
            "content": .string(content),
        ])
    }

    private mutating func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)_\(counter)"
    }
}

/// The call's spoken transcript, oldest first.
struct VoiceLiveTranscript {
    static let windowMs: Double = 5 * 60_000
    static let maxContextFragments = 80

    private(set) var fragments: [VoiceLiveTranscriptFragment] = []

    mutating func append(_ fragment: VoiceLiveTranscriptFragment) {
        fragments.append(fragment)
        if fragments.count > 2_000 { fragments.removeFirst(fragments.count - 1_500) }
    }

    /// What a delegation hands Hermes: the last five minutes, at most 80 fragments.
    var contextWindow: [VoiceLiveTranscriptFragment] {
        guard let last = fragments.last else { return [] }
        let floor = last.endMs - Self.windowMs
        return Array(fragments.filter { $0.endMs >= floor }.suffix(Self.maxContextFragments))
    }
}

/// Feeds a streaming reply to the voice: only finished sentences while it streams, the
/// rest when the turn ends. It keeps the exact speakable text already sent, so a reply
/// rebuilt from a snapshot continues where it left off when what was spoken is still its
/// prefix.
struct VoiceLiveSpeechCursor {
    private(set) var spoken = ""

    /// The next speakable text of `reply` (raw Markdown, the whole reply so far), or nil
    /// when nothing new is ready or the reply no longer starts with what was spoken.
    mutating func advance(reply: String, finished: Bool) -> String? {
        let text = VoiceLiveProtocol.speakableText(reply)
        guard text.hasPrefix(spoken) else { return nil }
        let rest = Array(text.dropFirst(spoken.count))
        let cut: Int
        if finished {
            cut = rest.count
        } else {
            // A link still streaming reads as `[text` until its target closes; speaking
            // into it would leave a `[` the finished text no longer has.
            let restText = String(rest)
            let openLink = restText.range(of: #"\[[^\]\n]*(\](\([^)\n]*)?)?$"#, options: .regularExpression)
            let limit = openLink.map { restText[..<$0.lowerBound].count } ?? rest.count
            cut = VoiceLiveProtocol.sentenceEnds(in: rest, streaming: true).last { $0 <= limit } ?? 0
        }
        guard cut > 0 else { return nil }
        let piece = String(rest[..<cut])
        spoken += piece
        return piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : piece
    }
}

enum VoiceLiveProtocol {
    /// The vendor caps an append at 500 tokens. Latin text runs about four characters per
    /// token and CJK about one, so a chunk weighs CJK characters 1400/300 times as much:
    /// 1400 Latin characters or 300 CJK ones fill it, and a mostly CJK chunk stops at 300.
    private static let appendBudget = 4_200
    private static let mostlyCJKLimit = 300
    private static let latinWeight = 3
    private static let cjkWeight = 14

    // MARK: Delegation and history

    /// Turns the transcript window into a Hermes turn: `prompt` is what the user said last
    /// (the persisted user row), `context` the recent spoken exchange (`voice_context`).
    static func delegationPrompt(_ fragments: [VoiceLiveTranscriptFragment]) -> (prompt: String, context: String) {
        let turns = turns(fragments)
        let prompt = collapsedWhitespace(turns.last { $0.speaker == .user }?.text ?? "")
        let context = turns.compactMap { turn -> String? in
            let text = collapsedWhitespace(turn.text)
            guard !text.isEmpty else { return nil }
            return "\(turn.speaker == .user ? "User" : "Voice assistant"): \(text)"
        }.joined(separator: "\n")
        return (prompt.isEmpty ? String(context.suffix(400)) : prompt, context)
    }

    /// Consecutive fragments of one speaker joined into a turn, oldest first.
    static func turns(_ fragments: [VoiceLiveTranscriptFragment]) -> [(speaker: VoiceLiveSpeaker, text: String)] {
        var turns: [(speaker: VoiceLiveSpeaker, text: String)] = []
        for fragment in fragments {
            if let last = turns.last, last.speaker == fragment.speaker {
                turns[turns.count - 1].text += fragment.text
            } else {
                turns.append((fragment.speaker, fragment.text))
            }
        }
        return turns
    }

    /// Seeds a new session with the chat's latest text turns: at most `maxMessages`
    /// messages and `maxCharacters` in all, each cut to 1200, newest kept.
    static func liveHistory(
        _ turns: [(speaker: VoiceLiveSpeaker, text: String)],
        maxMessages: Int = 24,
        maxCharacters: Int = 6_000
    ) -> [BotJSON] {
        var messages: [BotJSON] = []
        var budget = maxCharacters
        for turn in turns.reversed() {
            let text = String(collapsedWhitespace(turn.text).prefix(1_200))
            guard !text.isEmpty else { continue }
            if messages.count >= maxMessages || budget < text.count { break }
            budget -= text.count
            messages.append(.object([
                "type": .string("message"),
                "role": .string(turn.speaker == .user ? "user" : "assistant"),
                "content": .array([.object([
                    "type": .string(turn.speaker == .user ? "input_text" : "output_text"),
                    "text": .string(text),
                ])]),
            ]))
        }
        return messages.reversed()
    }

    // MARK: Speech text

    /// Markdown made fit to read aloud: code blocks dropped (an unclosed one up to the end,
    /// so a block still streaming is never read), list and heading markers, link targets
    /// and emphasis removed. Markers are deleted rather than paired so the result only
    /// grows as the reply streams.
    static func speakableText(_ markdown: String) -> String {
        var kept: [Substring] = []
        var inFence = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let lead = line.drop { $0 == " " || $0 == "\t" }
            if lead.hasPrefix("```") || lead.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if !inFence { kept.append(line) }
        }
        let withoutOrderedMarkers = kept.joined(separator: "\n")
            .replacingOccurrences(of: #"(?m)^[ \t]{0,3}\d{1,9}[.)][ \t]+"#, with: "", options: .regularExpression)
        return (SpeechTextNormalizer.normalizedAssistantText(withoutOrderedMarkers) ?? "")
            .replacingOccurrences(of: #"\*+|~~|__"#, with: "", options: .regularExpression)
    }

    /// Splits speakable text into `session.commentary.append` contents, packing whole
    /// sentences up to the append budget and cutting only a sentence that alone exceeds it.
    static func commentaryChunks(_ text: String) -> [String] {
        let characters = Array(text)
        var sentences: [String] = []
        var start = 0
        for end in sentenceEnds(in: characters, streaming: false) + [characters.count] where end > start {
            sentences.append(collapsedWhitespace(String(characters[start..<end])))
            start = end
        }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences where !sentence.isEmpty {
            if !fitsAppend(sentence) {
                if !current.isEmpty { chunks.append(current); current = "" }
                var rest = Substring(sentence)
                while !rest.isEmpty {
                    let piece = prefixFittingAppend(String(rest))
                    chunks.append(piece)
                    rest = rest.dropFirst(piece.count)
                }
                continue
            }
            let joiner = current.last.map(isCJK) == true && sentence.first.map(isCJK) == true ? "" : " "
            let candidate = current.isEmpty ? sentence : current + joiner + sentence
            if fitsAppend(candidate) {
                current = candidate
            } else {
                chunks.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Character offsets just past each sentence end: a newline, `。！？` (with closing
    /// quotes or brackets), or `.!?` followed by whitespace or CJK. While `streaming`, a
    /// trailing `.!?` is not an end yet (`3.` may become `3.14`).
    static func sentenceEnds(in characters: [Character], streaming: Bool) -> [Int] {
        var ends: [Int] = []
        for (index, character) in characters.enumerated() {
            var end = index + 1
            if character.isNewline {
                ends.append(end)
                continue
            }
            let isCJKEnd = "。！？".contains(character)
            guard isCJKEnd || ".!?".contains(character) else { continue }
            while end < characters.count, closers.contains(characters[end]) { end += 1 }
            if !isCJKEnd {
                if end == characters.count {
                    if streaming { continue }
                } else if !(characters[end].isWhitespace || isCJK(characters[end])) {
                    continue
                }
            }
            if end > (ends.last ?? 0) { ends.append(end) }
        }
        return ends
    }

    static func collapsedWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The longest prefix of `text` that fits one append.
    static func prefixFittingAppend(_ text: String) -> String {
        var cost = 0
        var count = 0
        var cjk = 0
        for character in text {
            let isCJKCharacter = isCJK(character)
            cost += isCJKCharacter ? cjkWeight : latinWeight
            cjk += isCJKCharacter ? 1 : 0
            if !fits(cost: cost, count: count + 1, cjk: cjk) { break }
            count += 1
        }
        return String(text.prefix(count))
    }

    private static let closers: Set<Character> = ["\"", "'", ")", "”", "’", "」", "』", "）", "】"]

    private static func fitsAppend(_ text: String) -> Bool {
        let cjk = text.reduce(0) { $0 + (isCJK($1) ? 1 : 0) }
        return fits(cost: cjk * cjkWeight + (text.count - cjk) * latinWeight, count: text.count, cjk: cjk)
    }

    private static func fits(cost: Int, count: Int, cjk: Int) -> Bool {
        cost <= appendBudget && (cjk * 2 <= count || count <= mostlyCJKLimit)
    }

    /// Han, kana, Hangul, and full-width forms: about one vendor token per character.
    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
             0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
