# 0031. Voice input and voice notes

Area: chat-composer

## Match dictation locales exactly before by language and region

`SFSpeechRecognizer.supportedLocales()` lists locales that a loose match confuses, such as `hi-IN` and `hi-IN-translit`. The locale resolver walks its `candidates` in order, calls `recognizer` only for candidates listed in `supportedLocales` and with the supported locale itself, and returns the first non-nil result; `recognizer` returns nil when that locale has no on-device model. An exact identifier match wins over a language plus region match, so `hi-IN` never resolves to `hi-IN-translit`. The fallback key is language plus region, lowercased: `en_US`, `en-US`, and `en_US@rg=pkzzzz` all normalize to `en-us`, and `zh-Hans-CN` to `zh-cn`, because `supportedLocales()` lists Chinese without a script. An identifier without a region (`en`) keeps its exact form.

Lives in: `HermesMobile/Features/Chat/ComposerVoiceInputController.swift`

## Treat only a Hermes host's empty transcript as silence

A Hermes host answers a quiet recording with `{ok: true, transcript: ""}` (#1071). `ComposerVoiceInputController` treats an empty transcript that the transcriber reports as a success (`ok == true`, no `error`) as silence: nothing to insert, nothing failed. webui's transcriber drops `ok` from an empty reply, so an empty webui answer stays the failure it was before #1071 and goes through `fallbackFromServerFailure`.

Lives in: `HermesMobile/Features/Chat/ComposerVoiceInputController.swift`, `HermesMobile/Networking/Hermes/HermesTranscription.swift`, `HermesMobileTests/ComposerVoiceInputServerRecordingTests.swift`

## Schedule the voice note ticker in .common run loop mode

`ComposerVoiceNoteRecorder` schedules its ticker timer in the `.common` run loop mode so it keeps firing while the transcript scrolls. In the default mode the timer pauses during scroll tracking.

Lives in: `HermesMobile/Features/Chat/ComposerVoiceNoteRecorder.swift`

## Leave the audio session alone while dictation captures

The inline audio player and composer dictation share one `AVAudioSession`. A flag tracks whether the composer is actively capturing microphone audio, and the inline player consults it before commandeering the session: switching it to `.playback` mid-capture would tear down the live recording engine and silently interrupt dictation. While dictation captures, the player leaves the session alone; `.playAndRecord` already supports playback, so the clip still plays through the active session.

Lives in: `HermesMobile/Features/Chat/InlineAudioPlayerView.swift`

## Send a voice note as the bare transcript

A server-transcribed voice note (`ChatViewModel.sendVoiceNote`) sends the transcript as the message text with no "[Attached files: …]" marker, so the model sees exactly the transcript and does not try to "inspect" (transcribe) the clip itself instead of answering it (#330). The clip still rides along as a display-only attachment so the inline player renders and persists; the server strips this attachment metadata before the model call, so it never reaches the agent. On reload the server often returns the clip attachment as a bare filename with no path while the optimistic bubble holds the full upload path, and `ChatViewModel.mergingLoadedMessages` must still match them so the optimistic message is not re-inserted as a duplicate user turn.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`, `HermesMobileTests/ChatViewModelSendTests.swift`, `HermesMobileTests/ChatViewModelMergeDedupTests.swift`

## Suspend room dictation while the app is locked

As in a Bot Chat (#885), `BotRoomComposerView` suspends voice input while `AppLock` is locked or the scene is not active, and resumes it only when the app is unlocked and active. The draft stays locked from the mic tap until the words have landed.

Lives in: `HermesMobile/Features/Bots/BotRoomComposerView.swift`

## Resign the room editor before dictation starts

A live composition commits only as the editor lets go, and dictation's baseline has to include that edit, so `BotRoomComposerView` sends `ComposerChipTextView.resignForDictation` before it schedules the toggle and refocuses the editor after dictation ends if it was focused.

Lives in: `HermesMobile/Features/Bots/BotRoomComposerView.swift`

## Transcribe a room's dictation with the host's default Profile

A group room has no Profile of its own: it lives in the host's `default` Profile, so its dictation borrows that Profile's speech-to-text, on the same saved connection the Bot inbox opened the room with.

Lives in: `HermesMobile/Networking/Hermes/HermesTranscription.swift`, `HermesMobile/Features/Bots/BotRoomComposerView.swift`
