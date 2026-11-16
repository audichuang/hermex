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
The microphone usage string says the same. Over the same peer connection's data
channel the phone also sends the agent's reply text and tool names (commentary
and thinking appends) to OpenAI, and the session the host mints is seeded with
the chat's recent text turns (`history`). Hermex runs no relay or server for
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
3. The reply (`message.delta`, and `message.interim` not already streamed)
   goes into the voice as commentary a finished sentence at a time: a newline,
   `。！？`, or `.!?` followed by whitespace or CJK. An append holds at most 1400
   Latin or 300 CJK characters (the vendor caps it at 500 tokens). Code blocks,
   list and heading markers, link targets and emphasis are stripped. A new tool
   sends one quiet thinking line. At the turn's end the unspoken rest of the
   reply, as the chat shows it, is spoken; a turn with nothing speakable sends the
   quiet line "Hermes finished that request without a spoken result."

### Turn claim

A delegation goes out only while the chat is idle. If a turn is running, the
call stops it once and waits up to 10 s for the chat to go idle; otherwise it
says "Sorry, I could not reach Hermes for that request." and drops it. A Stop
the host refused is not retried for that request, and neither it nor a wait that
ran out holds back the next request's Stop. The call
then claims the turn its own submit started (the coordinator's turn count, and
on a canonical host the reply's `admission_id`), speaks only that turn's frames,
and settles when the coordinator finishes the turn, whichever way it ends. A
newer delegation replaces the one in flight: the old turn is no longer spoken,
and if it is still running it is stopped first. After lost frames the call keeps
its claim only when the snapshot's running turn is provably the same (same start,
or on a canonical host the same started admission); otherwise it says "Hermes
finished; the result is in the chat." A kept turn's reply is rebuilt from the
chat, and the rest is spoken only while what was already spoken still starts it.

### Approvals during a call

The chat and its request cards stay on screen during a call. When the claimed
turn waits on an approval, clarify, or other host request, the voice says
"Hermes needs your approval on the phone screen." A new delegation while that
request is unanswered is not sent and does not stop the turn (a Stop would deny
the approval); the voice says "That request is still waiting for your approval
on the phone screen." The check runs again right before each Stop, so a request
waiting behind one turn is dropped the same way when the next turn already waits
on an approval.

## Start Voice Call

The "Start Voice Call" App Shortcut (`NewVoiceCallIntent`, assignable to the
Action button) opens a new chat on the active Hermes server in its New Session
Profile, as New Chat with Voice does. It has no URL: other apps and links in a
reply open URLs without asking, and a call opens the microphone and bills the
host's OpenAI key. The intent runs in the app and leaves
`AppIntentRouter.pendingVoiceCall`, which `ContentView` drains on launch and on
change, as it does the intents' deep links. Once that chat's Call gate has
answered, and the app is active and unlocked, the chat starts the call through
Call's own path, once per request; a gate that doesn't offer a call shows why in
the composer instead (the host's `reason` when the Profile chose GPT-Live, else
what a call needs). A gate read that fails ends the request with "The voice call
could not connect. Try again in a moment." in the composer, so a later read never
starts a call long after the press. On a webui server it opens New Chat with
Voice.

## Lifecycle and background

- While a call is on, the chat's connection keeps its gateway socket through the
  background (`HermesConnection.keepsAliveForCall`) and the chat skips
  `suspendStreamForBackground`, so the reply keeps streaming into the call. When
  the call ends in the background, the #902 close happens then. The `audio`
  background mode is already declared. Whether a call survives a locked screen
  has not been verified; it needs a physical device.
- A screen pushed over the chat (Files, a Profile editor, a fork's origin,
  another session) keeps the call and the chat's stream, so the reply keeps
  reaching the call; the stream suspends when the call ends while the chat is
  covered. Closing the chat releases its model, which ends the call.
- The call ends on End, the chat closing, the host replacing a Bot Chat, an audio
  interruption (phone call, Siri), the data channel or peer connection closing,
  another call starting, and after 10 minutes with no speech and no delegation
  out. A delegation whose turn waits on an approval or question counts as quiet
  from when it started waiting. When the chat loses its Hermes connection and
  it isn't back within 2 minutes, the delegation out is dropped with the
  unreachable line, so the 10 minutes run again. A route change does not end it.
- End silences the call at once: the microphone track and the voice's audio are
  disabled while the session waits up to 15 s for `session.closed`. An End
  while the session is still opening tears it down at once and the opening stops
  at its next step. If the host minted the session meanwhile, nothing on the
  phone can close it: the peer connection it was minted for is already gone, so
  it never connects.
- The call owns `.playAndRecord` + `.voiceChat` on the speaker with Bluetooth
  allowed, and restores the previous session when it ends. It holds the
  microphone and audio session process-wide (`ComposerAudioCaptureState`) from
  opening until its teardown has put the session back: meanwhile every
  composer's mic, dictation and voice notes are off, and a new call tears the
  old one down first, so the old one's restore can't land on the new one.
  `RTCAudioSession.setActive(false)` deactivates with
  `.notifyOthersOnDeactivation`, so audio the call paused can resume.

## Out of scope (follow-ups)

- Chained mode (speech-to-text → turn → text-to-speech) and streaming read-aloud (#1740).
- A spoken stop word.
- CallKit, ringing and VoIP push.
- A Live Activity for a call.
- A speaker/receiver toggle (calls use the speaker).
