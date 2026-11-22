# 0012. Bot room messaging

Area: bots

## Never annotate room sends with bot identification

In `BotRoomMentions`, room handles are server routing keys; friendly names only help searching. Unlike a bot's chat, a room send must never append an identification annotation.

Lives in: `HermesMobile/Features/Bots/BotRoomComposerView.swift`

## Hold the confirmed room action separately from the card

The room action card keeps the action whose Discard is being confirmed in its own `confirmingDiscard` state, apart from `action`. Room cards are keyed by position, so a poll can hand the card another task while the confirmation sheet is open, and confirming must still act on the task the user saw.

Lives in: `HermesMobile/Features/Bots/BotRoomComposerView.swift`

## Let each visible room screen claim socket ownership

A room and its profile screen share one `BotRoomReader`, but each visible screen claims async ownership through the owner token `BotRoomReader.open` takes. Navigation callbacks can arrive in either order, and the old screen must not close the new screen's socket.

Lives in: `HermesMobile/Features/Bots/BotRoomReader.swift`

## Never resend room commands automatically

`BotRoomReader.send` starts a new thread from the overview and continues the current discussion from detail. Only the dedicated retry button reuses an uncertain send's event id and payload. `BotRoomReader.command` checks ownership and the pending tuple inside `BotClient`'s actual socket write closure. A matching server event id in the loaded log settles an uncertain send without resending. For an attachment send, a retry rejection before admission triggers the log check below.

Lives in: `HermesMobile/Features/Bots/BotRoomReader.swift`

## Poll a room after every command reply

`BotRoomReader.command` reads room state after every acknowledgment or rejection, including codes 5118 and 5119. Action tuples marked inactive stay inert even if a stale server snapshot repeats them.

Lives in: `HermesMobile/Features/Bots/BotRoomReader.swift`

## Hide in-flight room sends and reconcile uncertain sends from the log

A poll can race the send acknowledgment, so `BotRoomReader.publishLog` hides the matching `message.user` event while the RPC result is pending. Once the send becomes uncertain, that exact event confirms delivery and frees its composer. The host derives the event id from the client id and rejects a retry that changes the payload. Missing history leaves the draft available for explicit Retry.

Desktop lets a send finish through navigation, shows the log event as soon as it arrives, and exposes Retry on the send button once the outcome is uncertain. Hermex suspends the room socket on backgrounding or navigation, so a lost reply can leave the send hidden and the composer locked even when the host received it. Matching the event in already-loaded history resolves that case immediately, even if the next poll has no new events.

Lives in: `HermesMobile/Features/Bots/BotRoomReader.swift`

## Show a thread's first message as the lead routing it

Under `routing: lead`, a thread's first message goes to the lead alone until the lead names who takes it, so `BotRoomRound` shows the lead choosing rather than counting the whole room. Otherwise a message reaches the lead's `room.assignment` members, else the members it @mentions (unless it says `@all` or `@everyone`), else the whole room.

Lives in: `HermesMobile/Features/Bots/BotGroupRoom.swift`

## Give the lead's routing turn no seat in a round

The lead's routing turn settles under the `room.assignment` event's task id: it chose who answers, it did not pass on the message. `BotRoomRound` skips settle, fail and cancel events for those task ids, or the strip would count the lead as a member that passed.

Lives in: `HermesMobile/Features/Bots/BotGroupRoom.swift`

## Poll a room every second for 20 s after a send

Right after a send the round has not started, so the idle status cadence would miss the lead's routing. `BotRoomReader.pollInterval` is 1 s for 20 s after `sentAt`, then the host's status interval.

Lives in: `HermesMobile/Features/Bots/BotRoomReader.swift`

## Bound automatic room attachment reads on the room socket

Both user and member attachments belong to the log event that carries their manifest.
The download RPC needs that event's ID to authorize access. It shares the reader's
socket with state and log polling. The 12,000,000-byte limit leaves room for base64
and JSON in a 16 MiB frame. Two concurrent automatic image previews limit contention
with polling. Leaving the viewport drops a queued preview, while an admitted read
can finish and warm the room-scoped image cache. A manual download can join a read
already in flight or start without waiting for an automatic slot.

`BotRoomPreviewSlot` keeps a loaded picture while the room passes through idle and
connecting on reopen or foregrounding, so the card does not collapse and reload;
only a missing picture waits for a live room. Rows and thread previews receive their
own file summary from the parent instead of reading `attachmentLists`, so a new
attachment elsewhere does not invalidate every row.

Lives in: `HermesMobile/Features/Bots/BotRoomAttachments.swift`, `HermesMobile/Features/Bots/BotRoomReader.swift`

## Keep the uploaded bytes stable across retries

The host deduplicates uploads by room and upload ID. It rejects an ID reused
with different bytes or metadata. Use the host's byte signatures for its five
image types, and convert other decodable image formats to JPEG once. The room
uses the shared picker’s selected image data before chat-specific compression so
it can retain formats like animated GIF. Keep the resulting bytes through an upload failure so an explicit retry can reuse them.
A successful upload needs only the returned manifest. A removed chip leaves
its uncommitted data for the host to reclaim after an hour.

Lives in: `HermesMobile/Features/Bots/BotRoomAttachments.swift`, `HermesMobile/Features/Bots/BotRoomReader.swift`

## Check the room log before restoring an uncertain attachment send

Unsent attachment chips expire locally after 55 minutes, five minutes before
the host can remove them. A committed event retains its attachments, so an
explicit retry may still be safe after that deadline. The canonical gateway
reports expired manifests as `invalid_params`. A standalone gateway reports
`5112` with `data.admitted: false`. After either rejection, a successful poll
lets the reader reconcile a matching event through the same log check. If the
event is absent, restore the text and ask the user to attach the files again.
A failed poll leaves the send uncertain while delivery is unconfirmed.

Lives in: `HermesMobile/Features/Bots/BotRoomReader.swift`
