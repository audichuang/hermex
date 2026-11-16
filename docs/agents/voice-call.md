# Voice call

A voice call lets the user talk to their agent hands-free on a Hermes chat, the
way Hermes Desktop's `voice.voice_chat_mode: gpt-live` does (#1091). OpenAI's
live voice model (`gpt-live-1`) handles speech in and out over WebRTC; it has no
tools, so real work goes to Hermes as an ordinary turn on the open chat and the
reply is spoken back. webui servers never offer it.

## Where call audio goes

Call audio goes from the phone directly to OpenAI over WebRTC, not through the
user's host. The host mints the session with its own OpenAI key and returns only
the session id and the vendor's SDP answer; the key never reaches the phone.
The microphone usage string says the same. Hermex runs no relay or server for
calls.

## Host contract

Read at the `HERMES_AGENT_TESTED_SHA` pin 3b421578 (`hermes_cli/web_routers/audio.py`,
`tools/voice_live.py`, `tui_gateway/methods_prompt.py`) and checked against
`scripts/local-hermes` with no OpenAI key. Both routes take `?profile=` and live in
`HermesREST` (`voiceLiveStatus`, `voiceLiveSession`).

- `GET /api/audio/voice-live/status` → `{ok, mode, available, reason, model, voice}`.
  `mode` is the Profile's `voice.voice_chat_mode` (`chained` or `gpt-live`).
  `available` only says an OpenAI key resolves, and the generic `OPENAI_API_KEY`
  counts, so Call shows only when `mode == "gpt-live" && available`, as on
  Desktop. An older host's 404 means no Call. On `scripts/local-hermes` at the pin:
  `200 {"ok":true,"mode":"chained","available":false,"reason":"no OpenAI API key (...)","model":"gpt-live-1","voice":"marin"}`.
  Read per chat as it attaches, never cached, so one server's answer can't gate
  another's.
- `POST /api/audio/voice-live/session` `{sdp, history}` → `{ok, session: {id}, transport: {type, sdp}}`.
  The offer goes byte-exact: the vendor refuses one without its trailing CRLF.
  `history` seeds the voice with the chat's recent text turns. 400 for an empty
  offer, 502 `{detail}` when the vendor refuses, 503 `{detail}` without a key; on
  `scripts/local-hermes` at the pin:
  `503 {"detail":"GPT-Live needs an OpenAI API key (OPENAI_API_KEY or voice.gpt_live.api_key)"}`.
  The app shows `detail` as written. The route waits on OpenAI, so it uses the
  `.provisioning` deadline.
- There is no route that ends a session: closing the peer connection does, and
  the session is billed until then.
- `prompt.submit` takes `surface: "voice-live"` and `voice_context` (the recent
  spoken transcript) on both dashboard and canonical hosts. The host truncates
  `voice_context` to 6000 characters and feeds it to the model only; the stored
  user row stays the prompt text.
- The voice talks on the `oai-events` data channel. Server events used:
  `session.started`, `session.input_transcript.delta`,
  `session.output_transcript.delta`, `session.delegation.created`, `error`
  (`context_injection_incomplete` ignored), `session.closed`. Client events sent:
  `session.commentary.append` (spoken), `session.thinking.append` (quiet
  progress), `session.input_audio.mute`/`unmute`, `session.close`.

## Flow

1. Call (beside the composer mic) asks for the microphone, opens the peer
   connection with no ICE servers, posts the offer, and the composer's toolbar
   becomes the call row: status, the latest caption, Mute, End.
2. The voice emits `session.delegation.created`. The call builds a prompt from
   the last user utterance and sends it as a Send on the chat with
   `surface: "voice-live"` and `voice_context`. The user row appears as usual; no
   staged files or draft are touched.
3. The reply streams into the voice as commentary a finished sentence at a time
   (`。！？!?.` or a newline), at most 1400 characters per append, 300 when the
   chunk is mostly CJK. Markdown is stripped. A new tool sends one quiet thinking
   line. At the turn's end the unspoken rest is spoken; a turn with nothing
   speakable says "Hermes finished that request without a spoken result."

### Turn claim

A delegation goes out only while the chat is idle. If a turn is running, the
call stops it once and waits up to 10 s for the chat to go idle; otherwise it
says "Sorry, I could not reach Hermes for that request." and drops it. The call
then claims the turn its own submit started (the coordinator's turn count, and
on a canonical host the reply's `admission_id`), speaks only that turn's frames,
and settles when the coordinator finishes the turn, whichever way it ends. A
newer delegation replaces the one in flight: the old turn is no longer spoken,
and if it is still running it is stopped first. After lost frames the reply is
rebuilt from the chat: if what was spoken is a prefix of the final text the rest
is spoken, otherwise "Hermes finished; the result is in the chat."

### Approvals during a call

The chat and its request cards stay on screen during a call. When the claimed
turn waits on an approval, clarify, or other host request, the voice says
"Hermes needs your approval on the phone screen." A new delegation while that
request is unanswered is not sent and does not stop the turn (a Stop would deny
the approval); the voice says "That request is still waiting for your approval
on the phone screen."

## Lifecycle and background

- While a call is on, the chat's connection keeps its gateway socket through the
  background (`HermesConnection.keepsAliveForCall`) and the chat skips
  `suspendStreamForBackground`, so the reply keeps streaming into the call. When
  the call ends in the background, the #902 close happens then. The `audio`
  background mode is already declared. Whether a call survives a locked screen
  is verified on a device only.
- The call ends on End, leaving the chat, the host replacing a Bot Chat, an audio
  interruption (phone call, Siri), the data channel or peer connection closing,
  and after 10 minutes with no speech and no delegation out. A route change does
  not end it. An End while the session is still opening closes it once it is up.
- During a call the composer mic and dictation are off, so they can't take the
  audio session; the call owns `.playAndRecord` + `.voiceChat` on the speaker with
  Bluetooth allowed, and restores the previous session when it ends.

## Out of scope (follow-ups)

- Chained mode (speech-to-text → turn → text-to-speech) and streaming read-aloud (#1740).
- A spoken stop word.
- CallKit, ringing and VoIP push.
- An App Intent or Shortcut that starts a call.
- A Live Activity for a call.
- A speaker/receiver toggle (calls use the speaker).
