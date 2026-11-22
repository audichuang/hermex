# 0011. Bot room creation and disband

Area: bots

## Keep history readable when the room driver is unavailable

The gateway still serves `groups.list`, `groups.state`, and `groups.log` when
the room driver is down. The capabilities flag gates creation and inbox room
commands. An open room uses each `groups.state` response: omission of
`driver_status` means the driver is unavailable, and a later response restores
participation and attachment transfers without reopening the room. The
unavailable notice stays pinned above the composer in `BotComposerPill` so long
threads anchored at the bottom still show why input is disabled.

Lives in: `HermesMobile/Features/Bots/BotGroupRoom.swift`,
`HermesMobile/Features/Bots/BotInbox.swift`,
`HermesMobile/Features/Bots/BotRoomReader.swift`,
`HermesMobile/Features/Bots/BotRoomComposerView.swift`, and
`HermesMobile/Features/Bots/BotRoomView.swift`

## Retry room creation with the same room id

`BotRoomCreator` gives one sheet one immutable create attempt: a deliberate retry uses the same room ID and payload, including after backgrounding or losing the socket, so an uncertain create never makes a second room. Another client can rename the room between a lost create reply and the retry, so the retry finds its earlier success in the room list by permanent ID and frozen members, not by name.

Lives in: `HermesMobile/Features/Bots/BotRoomCreator.swift`

## Recheck seatable bots at create and read rooms on Try Again

`BotRoomCreator` rechecks `seatableProfiles` at create, so a bot the host stopped seating since the sheet opened is never sent. The host refuses such a member before it looks for the room, so Try Again first reads the rooms: it adopts the room an earlier attempt made, or unlocks the choice when none was made.

Lives in: `HermesMobile/Features/Bots/BotRoomCreator.swift`

## Read every room page before concluding a disband

`BotRoomList.read` pages through the complete active-room list before an uncertain disband is judged to have removed its room. One missing page must never look like a successful deletion.

Lives in: `HermesMobile/Features/Bots/BotRoomCreator.swift`

## Recover an uncertain room disband with reads only

After a disband RPC, a disconnect may invalidate the write's continuation. `BotRoomReader` recovers by reading the room, never by resending disband, and only while the owning screen is still visible; backgrounding or closing leaves the link idle.

Lives in: `HermesMobile/Features/Bots/BotRoomReader.swift`
