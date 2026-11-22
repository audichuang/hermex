# 0181. Bot room settings

Area: bots

## Measure settings as the host does

`gateway/hosted_room_context.py` collapses whitespace in the purpose before
counting up to 500 Unicode code points. Counting Swift characters would let an
emoji sequence or a decomposed accent pass the form and fail on the host. The
notes limit is 4096 UTF-8 bytes after trimming, so a single displayed character
can consume multiple bytes. Python also counts U+001C through U+001F as
whitespace for both operations.

Lives in: `HermesMobile/Features/Bots/BotRoomContext.swift`

## Use acknowledged context for the room and preserve draft edits on refusal

`groups.context` requires both text fields even when clearing them. Omitting both
routing fields leaves the host's current routing in place, which allows editing
text on a host that returns a routing mode this client does not recognize. Every
explicit save gets its own event ID. After acknowledgment, invalidate any pending
state poll so a response that began before the acknowledgment cannot restore the
previous settings. The form retains the submitted draft on a refusal.

The progress strip can read the lead from state even when the settings event
predates the loaded log window. Older hosts that omit context still use the log
signal. The host snapshots settings when it admits a discussion, so a save does
not re-plan work already admitted.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`,
`HermesMobile/Features/Bots/BotRoomReader.swift`,
`HermesMobile/Features/Bots/BotGroupRoom.swift`,
`HermesMobile/Features/Bots/BotRoomSettingsView.swift`

## Preserve newer room settings for untouched fields

The settings draft records the values loaded when the form opens. On save,
routing and lead are omitted unless the user changed them so the host keeps its
current routing under its write lock, and an untouched purpose or notes field
uses the latest value polled into `reader.context` instead of the stale copy in
the draft. When both sides edit the same field, the user's draft wins without
merging. This intentionally differs from Hermes Desktop, which submits all four
fields from the form snapshot.

Lives in: `HermesMobile/Features/Bots/BotRoomSettingsView.swift`
