import XCTest
@testable import HermesMobile

final class VoiceLiveProtocolTests: XCTestCase {
    private func decode(_ json: String) -> VoiceLiveServerEvent? {
        VoiceLiveServerEvent.decode(Data(json.utf8))
    }

    func testDecodesTheEventsACallReactsToAndIgnoresTheRest() {
        XCTAssertEqual(decode(#"{"type":"session.started","session":{"id":"sess_1"}}"#), .started(sessionID: "sess_1"))
        XCTAssertEqual(
            decode(#"{"type":"session.input_transcript.delta","delta":"Hi ","start_ms":120,"end_ms":480.5}"#),
            .transcript(VoiceLiveTranscriptFragment(speaker: .user, text: "Hi ", startMs: 120, endMs: 480.5))
        )
        XCTAssertEqual(
            decode(#"{"type":"session.output_transcript.delta","delta":"Sure."}"#),
            .transcript(VoiceLiveTranscriptFragment(speaker: .assistant, text: "Sure.", startMs: 0, endMs: 0))
        )
        XCTAssertEqual(
            decode(#"{"type":"session.delegation.created","delegation":{"id":"del_7","type":"backend","target":"hermes"}}"#),
            .delegation(id: "del_7")
        )
        XCTAssertEqual(decode(#"{"type":"error","error":{"code":"rate_limited","message":"Slow down"}}"#), .error(message: "Slow down"))
        XCTAssertEqual(decode(#"{"type":"session.closed","reason":"idle_timeout","usage":{"seconds":42.5}}"#),
                       .closed(reason: "idle_timeout", usageSeconds: 42.5))

        XCTAssertNil(decode(#"{"type":"error","error":{"code":"context_injection_incomplete","message":"late"}}"#))
        XCTAssertNil(decode(#"{"type":"session.audio.level","level":3}"#))
        XCTAssertNil(decode(#"{"type":"session.delegation.created","delegation":{}}"#))
        XCTAssertNil(decode("not json"))
    }

    func testClientEventsCarryTheFieldsTheVendorReads() {
        var events = VoiceLiveClientEvents()
        let say = events.commentary("Done.", delegationID: "del_7")
        let think = events.thinking("  Hermes is working:\n terminal. ", delegationID: nil)
        let mute = events.inputAudio(muted: true)

        XCTAssertEqual(say.count, 1)
        XCTAssertEqual(say[0]["type"].text, "session.commentary.append")
        XCTAssertEqual(say[0]["delegation_id"].text, "del_7")
        XCTAssertEqual(say[0]["content"].text, "Done.")
        XCTAssertEqual(think?["type"].text, "session.thinking.append")
        XCTAssertEqual(think?.fields?["delegation_id"], .null)
        XCTAssertEqual(think?["content"].text, "Hermes is working: terminal.")
        XCTAssertEqual(mute["type"].text, "session.input_audio.mute")
        XCTAssertEqual(Set([say[0]["event_id"].text, think?["event_id"].text, mute["event_id"].text]).count, 3)
        XCTAssertEqual(VoiceLiveClientEvents.close["type"].text, "session.close")
    }

    func testLatinCommentaryIsCutOnSentenceBoundariesUnder1400Characters() {
        let sentence = "The deployment finished and every check passed on the first try."
        let text = Array(repeating: sentence, count: 60).joined(separator: " ")

        let chunks = VoiceLiveProtocol.commentaryChunks(text)

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 1_400)
            XCTAssertTrue(chunk.hasPrefix("The ") && chunk.hasSuffix("try."), chunk)
        }
        XCTAssertEqual(chunks.joined(separator: " "), text)
    }

    func testChineseCommentaryIsCutOnSentenceBoundariesUnder300Characters() {
        let sentence = "部署已經完成，所有檢查都在第一次就通過了！"
        let text = Array(repeating: sentence, count: 40).joined()

        let chunks = VoiceLiveProtocol.commentaryChunks(text)

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 300)
            XCTAssertTrue(chunk.hasPrefix("部署") && chunk.hasSuffix("！"), chunk)
        }
        XCTAssertEqual(chunks.joined(), text)
    }

    func testAStreamingChineseReplySpeaksOnlyFinishedSentencesThenTheTail() {
        var cursor = VoiceLiveSpeechCursor()
        var spoken: [String] = []
        let pieces = ["我查了", "一下，**測試**全部通過。", "接下來要", "部署嗎？目前", "版本是 3.", "14"]
        var reply = ""
        for piece in pieces {
            reply += piece
            if let next = cursor.advance(reply: reply, finished: false) { spoken.append(next) }
        }
        if let tail = cursor.advance(reply: reply, finished: true) { spoken.append(tail) }

        XCTAssertEqual(spoken, ["我查了一下，測試全部通過。", "接下來要部署嗎？", "目前版本是 3.14"])
        XCTAssertNil(cursor.advance(reply: reply, finished: true))
    }

    func testAReplyStreamedCharacterByCharacterIsSpokenWhole() {
        for reply in ["詳情請看[常見問題？點這裡](https://a.b/c)。完成。", "See [Dr. Smith's notes](https://x.y/z) now. Done."] {
            var cursor = VoiceLiveSpeechCursor()
            var spoken = ""
            var streamed = ""
            for character in reply {
                streamed.append(character)
                spoken += cursor.advance(reply: streamed, finished: false) ?? ""
            }
            spoken += cursor.advance(reply: reply, finished: true) ?? ""

            XCTAssertEqual(spoken, VoiceLiveProtocol.speakableText(reply))
        }
    }

    func testSpeakableTextDropsCodeAndMarkup() {
        let reply = """
        ## Result
        1. Ran **the tests** with [the runner](https://example.com/run).
        ```swift
        let x = 1
        ```
        - `make` is _fine_.
        """

        XCTAssertEqual(VoiceLiveProtocol.speakableText(reply), "Result\nRan the tests with the runner.\nmake is _fine_.")
        XCTAssertEqual(VoiceLiveProtocol.speakableText("Here:\n```\nrm -rf build"), "Here:")
    }

    func testDelegationMergesFragmentsAndPromptsWithTheLastUserUtterance() {
        var transcript = VoiceLiveTranscript()
        transcript.append(.init(speaker: .user, text: "Old request", startMs: 0, endMs: 1_000))
        transcript.append(.init(speaker: .user, text: "What's the ", startMs: 400_000, endMs: 401_000))
        transcript.append(.init(speaker: .user, text: "weather?", startMs: 401_000, endMs: 402_000))
        transcript.append(.init(speaker: .assistant, text: "Let me check.", startMs: 402_000, endMs: 403_000))
        transcript.append(.init(speaker: .user, text: " Run the  tests ", startMs: 403_000, endMs: 404_000))
        transcript.append(.init(speaker: .user, text: "too.", startMs: 404_000, endMs: 405_000))

        let delegation = VoiceLiveProtocol.delegationPrompt(transcript.contextWindow)

        XCTAssertEqual(delegation.prompt, "Run the tests too.")
        XCTAssertEqual(delegation.context, "User: What's the weather?\nVoice assistant: Let me check.\nUser: Run the tests too.")
    }

    func testLiveHistoryKeepsTheNewestTurnsWithinBudget() {
        let long = String(repeating: "a", count: 2_000)
        let turns: [(speaker: VoiceLiveSpeaker, text: String)] =
            (0..<10).map { (.user, "\($0)" + long) } + [(.user, "Latest question?"), (.assistant, "Latest   answer.")]

        let history = VoiceLiveProtocol.liveHistory(turns)

        XCTAssertEqual(history.count, 6)
        XCTAssertEqual(history.compactMap { $0["content"].list?.first?["text"].text?.count }.dropLast(2), [1_200, 1_200, 1_200, 1_200])
        XCTAssertEqual(history[4]["role"].text, "user")
        XCTAssertEqual(history[4]["content"].list?.first?["type"].text, "input_text")
        XCTAssertEqual(history[5]["role"].text, "assistant")
        XCTAssertEqual(history[5]["content"].list?.first?["type"].text, "output_text")
        XCTAssertEqual(history[5]["content"].list?.first?["text"].text, "Latest answer.")

        let many = (0..<30).map { (speaker: VoiceLiveSpeaker.user, text: "turn \($0)") }
        let capped = VoiceLiveProtocol.liveHistory(many)
        XCTAssertEqual(capped.count, 24)
        XCTAssertEqual(capped.first?["content"].list?.first?["text"].text, "turn 6")
    }

    /// Only a whole utterance that orders the request stopped counts; a request about stopping
    /// something, or words that also answer the voice, do not.
    func testAStopCommandIsTheWholeUtterance() {
        for text in ["Stop.", "Hermes, stop!", "please stop", "Cancel that.", "請停止。", "请停止", "停下來吧", "停下来", "取消"] {
            XCTAssertTrue(VoiceLiveProtocol.isStopCommand(text), text)
        }
        for text in ["Stop the build.", "How do I stop a process?", "never mind", "算了", "停止那個容器", ""] {
            XCTAssertFalse(VoiceLiveProtocol.isStopCommand(text), text)
        }
    }
}
