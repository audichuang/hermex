# Voice call

A voice call lets the user talk to their agent hands-free on a Hermes chat, the
way Hermes Desktop's `voice.voice_chat_mode: gpt-live` does (#1091). OpenAI's
live voice model (`gpt-live-1`) handles speech in and out over WebRTC; it has no
tools, so real work goes to Hermes as an ordinary turn on the open chat and the
reply is spoken back. Calls are a Hermes server's only: a legacy webui server
never offers one, its own chats or the Hermes chats on its Bots page, since the
call's way back to its chat lives in the Hermes home.

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

1. Call (beside the composer mic, in the collapsed pill and the card) dismisses
   the keyboard, asks for the microphone, opens the peer connection with no ICE
   servers, and posts the offer. The call opens full screen and rings until the
   session is up, then beeps and taps (see Ownership and the call screen); the
   composer stays as it was.
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
and if it is still running it is stopped first, unless the call's turn has
already started a tool. That turn may have acted, so stopping it loses work the
user then has to ask for again (twring ADR-026, from real Hermes calls): the new
request waits behind it instead (`queued`), the voice gets the quiet line "Hermes
is still working on the previous request. This one goes next, once it
finishes.", and further requests join it (newest 2000 characters kept). When the
turn settles its answer is spoken as usual and the queue goes out as one
delegation once the chat is idle, never by a Stop. Moving to another chat takes
the queue along as an unsent request; a Hermes connection that doesn't come back
drops it with the running one.

### Spoken stop

A user utterance that is wholly a stop order cancels the request out and the one
queued behind it (twring ADR-028). The voice model answers a bare "stop" itself
and doesn't delegate it (Desktop's `use-voice-live-conversation.ts`), so the call
judges the user's transcript 1.5 s after their last words
(`utteranceSettle`), and a delegation whose prompt is a stop order is never sent
to Hermes. `VoiceLiveProtocol.isStopCommand` matches the whole utterance without
spaces or punctuation: stop, stop it, cancel, cancel that, 停, 停止, 停下來, 取消,
with an address or particle around it ("Hermes, stop", "請停止"). "Never mind" and
算了 are left out: they also answer the voice's own questions. A running turn is
stopped and the voice says "Okay, Hermes stopped that request." (or that the host
refused the stop); one whose Send is still on the way is stopped once the host
starts it. With nothing out, a stop does nothing here. Unlike Desktop, where the
stop phrase ends the conversation, the call stays on. After lost frames the call keeps
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

## Calls and sessions

Upstream has no call object and no call session (read at upstream `e162dabd`).
The host mints a voice session from `{sdp, history?}` and the Profile alone and
keeps nothing; `session.id` in its answer is the vendor's. A call touches a
Hermes session only when a delegation goes out as `prompt.submit` on it, and
`surface: "voice-live"` marks that one turn, never the session
(`gateway/session_surface.py`). Desktop's call belongs to its window's composer
and delegates to whichever chat that window has open; its wake word opens a
fresh chat and starts the call there (`wake_word.start_new_session`, default on),
or starts it on the open chat when that is off. A new chat's session is created
by its first delegation, as by a typed first message. Hermex follows the same
model:

- **Where a call starts.** Call in any Hermes chat's composer (that session); New
  Voice Call in the Sessions list's New Session menu (long press) and the Start
  Voice Call Shortcut (a fresh session in the New Session Profile); Voice Call in a
  session row's context menu (that session). Each opens the chat with
  `HermesSessionChat.autoStartsVoiceCall`, which starts the call once the chat's
  gate answers, or shows why not. The menu entries hide while a call is on.
- **Which session it talks on.** The chat on screen. Opening another chat of the
  same server, saved connection and Profile moves the call there
  (`LiveVoiceCall.follow`, `HermesVoiceCall.move(to:)`): a delegation not yet sent
  and every later one goes to it; one already sent finishes in the chat it went to,
  is no longer spoken, and the voice is told its result is there. The voice is not
  seeded again. A chat in another Profile leaves the call where it is: the voice
  was minted with its Profile's key and voice. With no chat on screen (the list,
  Settings) the call stays on the last one.
- **Continuing a session.** End and Call again on the same chat: each call is a
  new voice session seeded with the chat's recent text turns, so what earlier calls
  delegated, and their replies, carry over; what the voice said without delegating
  is not stored (upstream #149111).

## Start Voice Call

The "Start Voice Call" App Shortcut (`NewVoiceCallIntent`, assignable to the
Action button) opens a new chat on the active Hermes server in its New Session
Profile, as New Chat with Voice does. It has no URL: other apps and links in a
reply open URLs without asking, and a call opens the microphone and bills the
host's OpenAI key. The intent runs in the app and leaves
`AppIntentRouter.pendingVoiceCall`, which `ContentView` drains on launch and on
change, as it does the intents' deep links. Once that chat's Call gate has
answered, and the app is active and unlocked, the chat starts the call through
Call's own path, once per request. While a call is on, the Shortcut goes back to
that call's chat instead of opening a new one; a gate that doesn't offer a call shows why in
the composer instead (the host's `reason` when the Profile chose GPT-Live, else
what a call needs). A gate read that fails ends the request with "The voice call
could not connect. Try again in a moment." in the composer, so a later read never
starts a call long after the press. On a webui server it opens New Chat with
Voice.

## Ownership and the call screen

- The call belongs to the app, not to the screen it started on. `LiveVoiceCall.shared`
  holds the call and its current chat's `ChatViewModel` until the call ends, so
  leaving the chat or going to Settings keeps it talking, its stream attached and its
  approval cards live; opening another chat of its Profile moves it there (§ Calls
  and sessions). There is one call per app: a request to call on a chat in another
  Profile goes back to the call that is on and builds no session.
- Any view that opens the call's chat (a list row, a Bot Chat, an Archived row, a
  session link, a push or Live Activity tap, a chat pushed from another) takes the
  call's model instead of making another (`LiveVoiceCall.model(for:)`, `ChatContinuity.resume`):
  the chat value it opened from, or the same server, connection and target (the
  Profile's Bot Chat, or the session by its current key or lineage root).
- Every call starts full screen (`LiveVoiceCallScreen`, a sheet from `ContentView`):
  an orb whose colours follow the phase and flow with the call's sound, the status
  and the latest words, the call's timer, and glass buttons for the audio output
  (the system's `AVRoutePickerView`: iPhone, Speaker, AirPods), Mute and End.
  Swiping it down or Minimize (`LiveVoiceCall.isExpanded`) leaves the pill.
- The pill (`LiveVoiceCallBar`) floats above `ContentView`'s content, stacked so every
  screen and its navigation bar starts below it (a top safe-area inset left the navigation
  bars under it); sheets still cover it. It shows a waveform of the call's level, the
  status (Muted over Listening), the timer, Mute and End; a tap opens the full screen.
  Show chat on the full screen minimizes it and goes back to the call's chat through
  the Hermes home, not a session link: Settings and Add Server close, then the bot's
  Bot Chat or the Sessions chat opens.
- The call ends on End, ten quiet minutes, switching server or signing out (and a
  replaced saved connection), the host replacing a Bot Chat, an audio interruption
  (phone call, Siri), or the data channel or peer connection closing. Every end but
  End and a server change is a drop: the pill keeps its reason with Call again, which
  starts a new call on the same chat, until dismissed. The ten minutes are counted
  from the last speech by either side or delegation out; there is no absolute cap. A
  delegation whose turn waits on an approval or question counts as quiet from when it
  started waiting. When the chat loses its Hermes connection and it isn't back within
  2 minutes, the delegation out is dropped with the unreachable line, so the 10
  minutes run again. A route change does not end it.

## Lifecycle and background

- While a call is on, the chat's connection keeps its gateway socket through the
  background (`HermesConnection.keepsAliveForCall`) and the chat skips
  `suspendStreamForBackground`, so the reply keeps streaming into the call. When
  the call ends in the background, the #902 close happens then. The `audio`
  background mode is already declared. Whether a call survives a locked screen
  has not been verified; it needs a physical device.
- With no view of the chat on screen, the call keeps the chat's stream; it suspends
  when the call ends.
- End silences the call at once: the microphone track and the voice's audio are
  disabled while the session waits up to 15 s for `session.closed`. An End
  while the session is still opening tears it down at once and the opening stops
  at its next step. If the host minted the session meanwhile, nothing on the
  phone can close it: the peer connection it was minted for is already gone, so
  it never connects.
- The call owns `.playAndRecord` + `.voiceChat` on the speaker with Bluetooth
  allowed (the output button moves it), with haptics allowed while recording for the
  connected tap. The ringback and beep are tones the app makes (`VoiceCallTones`),
  played beside WebRTC's audio and never into the microphone track. It restores the previous session when it ends. It holds the
  microphone and audio session process-wide (`ComposerAudioCaptureState`) from
  opening until its teardown has put the session back: meanwhile every
  composer's mic, dictation, voice notes and Call are off, and a new call tears
  down one still ending after End first, so the old one's restore can't land on
  the new one. `RTCAudioSession.setActive(false)` deactivates with
  `.notifyOthersOnDeactivation`, so audio the call paused can resume.

## Weak signal and reconnecting

Unlike Desktop, which ends a call on WebRTC's first `disconnected`, a phone call
rides out bad signal the way a phone call does (`HermesVoiceCall`, Reconnecting):

- `disconnected` is reported as `unstable`: the call shows Reconnecting… and gets
  6 s (`unstableGrace`) to come back on its own, which most short losses do.
- `failed`, the data channel closing, or the grace running out dials a fresh
  session (`redial`): the same host route on the chat the call talks on now,
  seeded with the chat's turns and then what was said on the call, which the
  chat doesn't hold. Each try gets 15 s, and they go 1/2/4/8 s apart (8 s
  repeating) until 60 s after the connection went down (`reconnectWindow`), then
  the call ends as `connection_lost`. A Wi-Fi to cellular switch lands here too:
  with no ICE restart on the host route, a new path needs a new session.
- A try that never reached the host (no signal) costs nothing, but every session
  the host mints is billed: at most 4 (`redialSessionLimit`) until a reconnected
  call has stayed up for 60 s (`stableAfter`), past which a drop ends the call.
- `VoiceCall` log lines record each peer connection state, connection change and
  redial outcome, for timing a drop on a device.
- The transport keeps the microphone claim, the audio session and the factory
  across a redial, and leaves the dropped peer open, unheard, until the new one
  connects, so WebRTC's audio unit keeps recording and a locked phone's app stays
  alive. A soft double beep repeats while it reconnects (`VoiceCallTones`), and
  the connected beep says it is back.
- Delegations and their turns carry on meanwhile. What the voice should say waits
  in `heldSpeech` and goes out once it can hear it; on a redialed session it goes
  without the old session's `delegation_id` (`null`, as Desktop's
  `session.instructions.append` sends), which that session never issued. A mute
  is sent again to the new session.
- A redialed session never heard what the dropped one may not have said yet
  (twring ADR-038). Each sentence sent counts as unheard until its estimated
  speaking time (about 14 Latin or 4.5 CJK characters a second, after what is
  ahead of it) plus 3 s (`heardSlack`, for the delay before a drop is noticed) has
  passed; what is unheard at the drop is said again first on a redialed session,
  at most twice per request (`maxReplays`). A short repeat beats a gap. A wavering
  connection that comes back is the same session and repeats nothing, and once
  the user speaks, nothing said before it is repeated. Known limit: a sentence
  sent before a waver that came back is no longer tracked, so a drop right after
  it doesn't repeat that sentence.
- A phone call or Siri (`interrupted`) and the vendor's own closes still end the
  call at once.

Not verified on a device yet: whether the dropped peer really keeps the audio
unit recording on a locked phone, and how the vendor treats a commentary with a
`null` id mid-call.

## Out of scope (follow-ups)

- Chained mode (speech-to-text → turn → text-to-speech) and streaming read-aloud (#1740).
- CallKit and VoIP push (the ringback is the app's own tone, not an incoming call).
- A Live Activity for a call.

## Diagnosing calls

- A drop's notice ends with the raw reason and how long the call was up, e.g.
  `(expired, 29s)`. `expired` near 30 s means OpenAI heard no microphone audio
  (always on the simulator, which has none); `connection_lost` means every redial
  failed after the peer connection dropped (see Weak signal and reconnecting);
  `interrupted` is a phone call or Siri.
- `VoiceCall` lines `Delegation <step> after <n> ms` time each request from the
  voice's delegation: `submitting`, `started` or `refused`, `first reply`, `first
  speech` (the first sentence sent to the voice), `settled`. Only steps and
  milliseconds are logged, never text or tool names.
- A delegated request that reached Hermes is an ordinary turn in the host's
  `agent.log` for that Profile; none during a call means the voice never
  delegated or the app never sent it. The session route itself logs nothing.
- `scripts/fork/voice-live-probe` places a real call from the Mac with the host's
  session config and spoken questions, and prints when the voice answers,
  delegates and closes, to tell the vendor side from the phone. It bills
  `OPENAI_API_KEY`.
