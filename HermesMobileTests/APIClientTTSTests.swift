import XCTest
@testable import HermesMobile

final class APIClientTTSTests: APIClientTestCase {
    func testSynthesizeSpeechPostsJSONAndReturnsRawAudioBytes() async throws {
        // Not valid MPEG audio — the client must return the bytes untouched,
        // never attempt to JSON-decode a 2xx TTS response.
        let audioBytes = Data([0xFF, 0xF3, 0x18, 0xC4, 0x00, 0x01])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/tts")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            guard let body = apiTestBodyData(from: request) else {
                XCTFail("Missing request body")
                throw URLError(.badServerResponse)
            }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["text"] as? String, "Hello from Hermex.")
            // The server defaults to `zh-CN-XiaoxiaoNeural`, so the voice must
            // always be sent explicitly.
            XCTAssertEqual(json["voice"] as? String, "en-US-AriaNeural")
            XCTAssertEqual(json["engine"] as? String, "edge")
            XCTAssertEqual(json.count, 3)

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, audioBytes)
        }

        let data = try await client.synthesizeSpeech(text: "Hello from Hermex.", voice: "en-US-AriaNeural")

        XCTAssertEqual(data, audioBytes)
    }

    func testProviderEngineIsExplicitAndAbsentVoiceUsesProviderConfiguration() async throws {
        for engine in [TTSEngine.openai, .elevenlabs] {
            let client = makeClient { request in
                let body = try XCTUnwrap(apiTestBodyData(from: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["text"] as? String, "Hello")
                XCTAssertEqual(json["engine"] as? String, engine.rawValue)
                XCTAssertNil(json["voice"], "No voice lets the provider's configured one apply")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data([1]))
            }
            let audio = try await client.synthesizeSpeech(text: "Hello", voice: nil, engine: engine)
            XCTAssertEqual(audio, Data([1]))
        }
    }

    func testSettingsDecodesTTSPreferencesTolerantly() async throws {
        for (json, engine, voice) in [
            (#"{"tts_engine":"edge","tts_voice":"tr-TR-EmelNeural"}"#, "edge", "tr-TR-EmelNeural"),
            (#"{}"#, nil, nil),
            (#"{"tts_engine":null,"tts_voice":null}"#, nil, nil),
            (#"{"tts_engine":[],"tts_voice":{"future":true}}"#, nil, nil),
            (#"{"tts_engine":12,"tts_voice":false}"#, nil, nil)
        ] as [(String, String?, String?)] {
            let client = makeClient { request in
                XCTAssertEqual(request.url?.path, "/api/settings")
                return apiTestJSONResponse(json, for: request)
            }
            let settings = try await client.settings()
            XCTAssertEqual(settings.ttsEngine, engine)
            XCTAssertEqual(settings.ttsVoice, voice)
        }
    }
}

/// Listen's speech from a Hermes host (#1072) over a connected `BotClient`, against a host
/// scripted with the replies `scripts/local-hermes` gave at the pin (0.21.5, ca678285).
@MainActor final class HermesSpeakTests: XCTestCase {
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    /// The host's provider picks the format; every format comes back as its bytes.
    func testSpeechIsTheTextSpokenInTheProfilesVoice() async throws {
        let client = try await connectedClient()
        defer { client.close() }
        var sent: URLRequest?
        _ = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/audio/speak" else { return nil }
            sent = request
            return .json(200, .object(["ok": .bool(true), "data_url": .string("data:audio/ogg;base64,T2dnUwACAA=="),
                                       "mime_type": .string("audio/ogg"), "provider": .string("openai")]))
        }

        let audio = try await client.speech(text: "Hi there.", profile: "research")

        XCTAssertEqual(audio, Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00]))
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertEqual(sent?.url?.query, "profile=research")
        XCTAssertEqual(try sent.flatMap(apiTestBodyData).map { try JSONDecoder().decode(BotJSON.self, from: $0) },
                       .object(["text": .string("Hi there.")]), "The host takes no voice, engine or rate")
    }

    func testARefusalOrAnUnreadableReplyThrows() async throws {
        let client = try await connectedClient()
        defer { client.close() }
        let refusals: [(String, HermesHostFixture.Reply)] = [
            ("empty text", .json(400, .object(["detail": .string("Text is required")]))),
            ("provider failure", .json(500, .object(["detail": .string("Speech synthesis failed")])))
        ]
        let unreadable: [(String, String?)] = [
            ("not base64", "data:audio/mpeg;base64,not*base64"),
            ("not base64-encoded", "data:audio/mpeg,T2dnUw=="),
            ("not a data URL", "https://hermes.example/speech.mp3"),
            ("no audio", "data:audio/mpeg;base64,"),
            ("no data_url", nil)
        ]
        let replies: [(String, HermesHostFixture.Reply)] = refusals + unreadable.map { label, url in
            var body: [String: BotJSON] = ["ok": .bool(true)]
            body["data_url"] = url.map(BotJSON.string)
            return (label, .json(200, .object(body)))
        }
        for (label, reply) in replies {
            _ = HermesHostFixture.configuration { $0.url?.path == "/api/audio/speak" ? reply : nil }
            do {
                _ = try await client.speech(text: "Hi.", profile: "research")
                XCTFail("\(label): expected a throw")
            } catch {
                if refusals.contains(where: { $0.0 == label }) {
                    XCTAssertEqual(error as? BotArtifactFailure, .unavailable, label)
                } else {
                    XCTAssertEqual(error as? BotFailure, .unsupported, label)
                }
            }
        }
    }

    private func connectedClient() async throws -> BotClient {
        let client = BotClient(http: BotSocketHost().connection(record))
        try await client.connect()
        return client
    }
}

/// A voice call's two host routes (#1091) over a connected `BotClient`, against a host scripted
/// with the replies `scripts/local-hermes` gave at the pin (3b421578) without an OpenAI key.
@MainActor final class HermesVoiceLiveTests: XCTestCase {
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    /// The Call button's gate: the Profile's mode and availability, and nothing from a host
    /// that predates the route.
    func testTheStatusReadsTheProfilesSetupAndAnOlderHostHasNone() async throws {
        let client = try await connectedClient()
        defer { client.close() }
        _ = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/audio/voice-live/status" else { return nil }
            return .json(200, .object(["ok": .bool(true), "mode": .string("chained"), "available": .bool(false),
                                       "reason": .string("no OpenAI API key (set OPENAI_API_KEY or voice.gpt_live.api_key)"),
                                       "model": .string("gpt-live-1"), "voice": .string("marin")]))
        }
        let status = try await client.voiceLiveStatus(profile: "research")
        XCTAssertEqual(status?.mode, "chained")
        XCTAssertEqual(status?.available, false)

        _ = HermesHostFixture.configuration { request in
            request.url?.path == "/api/audio/voice-live/status" ? .json(404, .object(["detail": .string("Not Found")])) : nil
        }
        let older = try await client.voiceLiveStatus(profile: "research")
        XCTAssertNil(older)
    }

    /// Call shows only for a Profile that chose GPT-Live and can run it: a key alone (the generic
    /// `OPENAI_API_KEY`) would otherwise offer a billed call on a chained Profile.
    func testCallShowsOnlyForAProfileThatChoseGPTLiveAndCanRunIt() {
        XCTAssertTrue(HermesVoiceLiveStatus(mode: "gpt-live", available: true).offersCall)
        XCTAssertFalse(HermesVoiceLiveStatus(mode: "chained", available: true).offersCall)
        XCTAssertFalse(HermesVoiceLiveStatus(mode: "gpt-live", available: false).offersCall)
    }

    /// The host waits on the vendor, so the offer goes out on the long deadline, and the answer
    /// comes back for the peer connection.
    func testTheSessionTradesTheOfferForTheAnswerOnTheLongDeadline() async throws {
        let http = BotSocketHost().connection(record)
        let client = BotClient(http: http)
        try await client.connect()
        defer { client.close() }
        let parked = expectation(description: "Offer in flight")
        HermesHostFixture.onPark = { parked.fulfill() }
        _ = HermesHostFixture.configuration { $0.url?.path == "/api/audio/voice-live/session" ? .park : nil }

        let running = Task { try await client.voiceLiveSession(profile: "research", sdp: "v=0\r\n", history: []) }
        await fulfillment(of: [parked], timeout: 2)
        let onLong = await http.provisioningSession.allTasks.contains { $0.originalRequest?.url?.path == "/api/audio/voice-live/session" }
        HermesHostFixture.releaseParked(.json(200, .object(["ok": .bool(true), "session": .object(["id": .string("sess_1")]),
                                                            "transport": .object(["type": .string("webrtc"), "sdp": .string("v=0\r\nanswer\r\n")])])))
        let session = try await running.value

        XCTAssertTrue(onLong)
        XCTAssertEqual(session, HermesVoiceLiveSession(sessionID: "sess_1", answerSDP: "v=0\r\nanswer\r\n"))
    }

    /// No key on the host (503) or a vendor refusal (502): the user reads the host's reason.
    func testARefusedSessionCarriesTheHostsReason() async throws {
        let client = try await connectedClient()
        defer { client.close() }
        let refusals: [(status: Int, detail: String)] = [
            (503, "GPT-Live needs an OpenAI API key (OPENAI_API_KEY or voice.gpt_live.api_key)"),
            (502, "GPT-Live session creation failed (401): invalid key")
        ]
        for refusal in refusals {
            _ = HermesHostFixture.configuration { request in
                request.url?.path == "/api/audio/voice-live/session"
                    ? .json(refusal.status, .object(["detail": .string(refusal.detail)])) : nil
            }
            do {
                _ = try await client.voiceLiveSession(profile: "research", sdp: "v=0\r\n", history: [])
                XCTFail("\(refusal.status): expected a throw")
            } catch {
                XCTAssertEqual(error as? HermesVoiceLiveRefusal, HermesVoiceLiveRefusal(status: refusal.status, detail: refusal.detail))
                XCTAssertEqual(error.localizedDescription, refusal.detail)
            }
        }
    }

    private func connectedClient() async throws -> BotClient {
        let client = BotClient(http: BotSocketHost().connection(record))
        try await client.connect()
        return client
    }
}
