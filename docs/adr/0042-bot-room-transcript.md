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
displayed count lower than the host's. Used continues take the maximum of the
loaded `room.continued` count and the highest integer `payload.grant` for that
discussion, so a windowed log still retires Continue once the host's cap is
reached.

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

## Prefer known reason codes over raw error text in turn notices

`turn.failed`, `turn.cancelled`, `turn.deferred`, and `member.unavailable` resolve their
reason text through `BotRoomReason.text(code:detail:)`:

1. If `reason_code` (or `reason` for cancelled/deferred turns) matches the gateway's
   21-entry vocabulary, display its localized label.
2. Otherwise, if `error` (or `reason`) contains free text (not a code-shaped token and
   not the server's default boilerplate `member turn cancelled` or `member turn failed` —
   suppressing `member turn failed` is a deliberate small divergence from Desktop so
   fallback failures do not repeat the base notice), display its first line verbatim.
3. Otherwise omit the detail and show only the base notice (with the member's name when
   that member is still in the roster, or without a name for departed members and
   room-level `member.unavailable`).

This deliberately diverges from Desktop's transcript rows (which check free-text `error`
first and therefore almost always surface raw English provider errors) and matches
Desktop's member status precedence (`OUTCOME_OF` / `memberStatusText`) so users get
localized explanations for known failures while still seeing raw error text when the host
classifies a failure as `unknown`. Room-level `member.unavailable` is the one exception:
its `reason_code` is always `prepare_failed`, so Hermex checks the first line of
free-text `error` first and falls back to the mapped code only when `error` is missing
or code-shaped, matching Desktop.

Lives in: `HermesMobile/Features/Bots/BotRoomReasons.swift` and
`HermesMobile/Features/Bots/BotGroupRoom.swift`

## Attribute scheduled posts by actor ID and resolve delivery-target Profile from the canonical roster

The gateway stamps cron posts into rooms as `message.user` events whose `actor.id` starts
with `cron:` or `cron-notice:` and whose `actor.display_name` holds the job name. Hermex
detects scheduled posts by `kind == "message.user"` and that `actor.id` prefix without
requiring `actor.kind == "user"`, because `BotHistoryCache.Message.roomEvent` restores only
`actor.id` and `actor.display_name`. That keeps scheduled posts left-aligned with their job
name and “Scheduled” badge across cold restarts, and keeps thread overview previews and
local search results attributed to the job name instead of “You”.

For the room profile’s copyable delivery target (`room:<room_id>[@<profile>]`), Hermex
cannot rely on `groups.capabilities.room_link.profile` (absent unless `room_link` is
enabled). On canonical connections (`speaksCanonicalProtocol`), `profiles.list` always puts
the gateway’s own served Profile first (`served_profile_name(home)`), so `BotInbox` records
that first row’s `name` (including `default`) as `hostProfile` and clears it on teardown /
connection change. Non-canonical connections leave `hostProfile` nil and show `room:<room_id>`
with a note to append `@profile` for jobs under another Profile.

Lives in: `HermesMobile/Features/Bots/BotRoomScheduledPost.swift`,
`HermesMobile/Features/Bots/BotInbox.swift`, `HermesMobile/Features/Bots/BotRoomView.swift`,
`HermesMobile/Features/Bots/BotRoomProfileView.swift`, and
`HermesMobile/Features/Bots/BotHistoryCache.swift`

## Derive member latest outcomes per thread from the loaded room log

The room profile displays each member's live activity (`Working` with optional tool, `Queued`,
or `Stopping…`) and, when idle, their latest turn outcome (`Failed` with localized reason via
`BotRoomReason.text(code:detail:)`, `No answer`, `Cancelled`, `Replied`, or `Skipped`).
`BotRoomReader.publishLog()` derives `memberOutcomes` from `roundEvents` (which includes
`turn.settled` signals) and compares before assigning so unchanged polls do not invalidate
views.

Matching Desktop's `memberOutcomes` rules, each thread tracks its current discussion as the
`event_id` of its newest `message.user`. Only terminal turns (`turn.settled`, `turn.failed`,
`turn.cancelled`, and `turn.deferred` with `reason == "member_unavailable"`) whose
`discussion_event_id` matches their thread's current discussion count; a newer user message in
the same thread retires older outcomes there without affecting other threads, and later events
for a member overwrite earlier ones. Terminal events whose `task_id` matches a `room.assignment`
event in the same discussion are skipped, matching `BotRoomRound`, so a lead's routing turn is
not reported as an answer or skip. Because Hermex loads rooms in pages and disk-cached rows
omit `discussion_event_id` and `turn.*`, outcomes reflect only loaded host-fetched events:
members whose last turn predates the loaded window show no outcome rather than a stale one.

Lives in: `HermesMobile/Features/Bots/BotRoomMemberStatus.swift`,
`HermesMobile/Features/Bots/BotRoomReader.swift`, and
`HermesMobile/Features/Bots/BotRoomProfileView.swift`
