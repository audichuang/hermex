import Foundation

/// A Profile's live voice setup on a Hermes host (#1091), `GET /api/audio/voice-live/status`.
/// Read per chat, never cached, so one server's answer can't gate another's. `mode` is the
/// Profile's `voice.voice_chat_mode` (`chained` or `gpt-live`); `available` only says an OpenAI
/// key resolves, which the generic `OPENAI_API_KEY` also satisfies.
struct HermesVoiceLiveStatus: Equatable, Sendable {
    let mode: String?
    let available: Bool
    let reason: String?
    let model: String?
    let voice: String?

    init(mode: String?, available: Bool, reason: String? = nil, model: String? = nil, voice: String? = nil) {
        (self.mode, self.available, self.reason, self.model, self.voice) = (mode, available, reason, model, voice)
    }

    init(_ body: BotJSON) {
        self.init(mode: body["mode"].text, available: body["available"].flag == true, reason: body["reason"].text,
                  model: body["model"].text, voice: body["voice"].text)
    }
}

/// A GPT-Live session the host minted for one call: the vendor's answer to the offer.
struct HermesVoiceLiveSession: Equatable, Sendable {
    let sessionID: String?
    let answerSDP: String
}

/// The host's reason for not starting a call (`{detail}`): 503 without an OpenAI key, 502 when
/// the vendor refused the session. Shown as the host wrote it.
struct HermesVoiceLiveRefusal: LocalizedError, Equatable {
    let status: Int
    let detail: String
    var errorDescription: String? { detail }
}
