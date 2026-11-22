# 0042. Bot room transcript

Area: chat-transcript

## Build room transcripts eagerly over a bounded window

Member replies in a bot room are hosted selection documents, and a lazy stack places unbuilt rows from an estimate, so the jump to a search hit missed on a cold open (#553). `BotRoomView` builds its transcript in an eager stack over a bounded window, `BotRoomTranscriptWindow`, which keeps the build to the newest page (`pageSize`, 50 events). `BotRoomTranscriptWindow.start` gives the index of the first shown event in the sequence-sorted `events`; an anchor outside the events (a reconnect restored a trimmed transcript, or the room restarted) falls back to the newest page. Its `keeping` argument widens the window to a search hit that is present, so the hit's row is built by the time the jump runs (#553).

Lives in: `HermesMobile/Features/Bots/BotRoomView.swift`

## Keep room thread rows on stable identity

`BotRoomTranscriptRow` uses a stable thread identity for rows in the overview, and exact sequence identities in thread detail and unthreaded history. A reply changes its thread's latest event, and it must not replace its overview row's identity; thread identity also survives activity reordering.

Lives in: `HermesMobile/Features/Bots/BotRoomView.swift`

## Yield before jumping to a room search hit

A pushed thread destination in `BotRoomView` lays out after the overview's synchronous search callback. The jump awaits `Task.yield` so those materialized rows exist before `proxy.scrollTo` runs.

Lives in: `HermesMobile/Features/Bots/BotRoomView.swift`

## Derive actionable pauses from the loaded room log

A bounded activity can arrive after the work it describes has been superseded.
A room stop or a newer user message in the same thread retires the pause if
it follows the discussion's source message, even if it precedes the bounded
notice. If the source is outside the loaded window, use the notice's sequence.
The count includes only loaded member messages carrying the discussion ID.
Earlier pages and messages restored from disk without that ID can make the
displayed count lower than the host's.

Stop is room-wide, including when invoked from a pause row while the room
is idle. It invalidates pauses across threads and asks for confirmation
when room work is queued or running. Hermex serializes room commands, so
the pause row's Stop waits for an in-flight Send or Continue to finish.
Desktop allows Stop during those requests.

Lives in: `HermesMobile/Features/Bots/BotRoomPauses.swift` and
`HermesMobile/Features/Bots/BotRoomReader.swift`

## Render routing lines and discussion-scoped handoffs

`room.assignment` and `room.routed` are visible transcript events (not hidden
round signals), so each appears once in `roundEvents`. `BotRoomReader.publishLog()`
drops routing events whose `routingText(in:)` is `nil` (such as a `room.routed`
naming only departed members) so no blank row renders.

Member-to-member handoffs are derived in `BotRoomReader.publishLog()` from
`roundEvents` (which includes `turn.settled`) and compared before assignment so
unchanged polls do not invalidate views. Unlike Desktop's legacy fallback for
events without `discussion_event_id`, Hermex requires a non-empty
`discussion_event_id` on both the member message and the subsequent terminal turn;
messages restored from disk cache omit that ID and must not match unrelated turns.

Lives in: `HermesMobile/Features/Bots/BotRoomRouting.swift`,
`HermesMobile/Features/Bots/BotGroupRoom.swift`, and
`HermesMobile/Features/Bots/BotRoomReader.swift`
