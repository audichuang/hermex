# 0013. Bot rooms and mentions

Area: bots

## Never section rooms and keep hidden rooms unhidable

`BotInbox.sections` never sections rooms, because Desktop keeps a room's section on the machine that filed it. A hidden room lives in the revealed list whether or not it is also pinned, exactly as a hidden bot does, so it can always be unhidden.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`

## Keep the room cursor when applying an early acknowledgment

An acknowledgment can arrive ahead of unread log events. `BotRoomLog.acknowledge` inserts its bubble but keeps the previous `cursor`, so the next log read does not skip those events.

Lives in: `HermesMobile/Features/Bots/BotGroupRoom.swift`

## Do not treat file paths as bot mentions

`BotMentions.tokens` runs a handle possessively to its end and does not count it as a mention when a path continues it (`@docs/plan.md`, `@docs.md`). The composer's file references then never resolve as a bot, while trailing punctuation after a handle still does.

Lives in: `HermesMobile/Features/Bots/BotMentions.swift`

## Reserved words block only friendly bot aliases

`BotMentions.nameForms` produces Desktop's slug and collapsed name forms. Reserved words only block friendly aliases, so the primary Profile still owns @hermes and @default.

Lives in: `HermesMobile/Features/Bots/BotMentions.swift`

## Address a thread member without breaking in-place selection

Follow-ups in an existing room thread do not route through a lead and wake every member unless the text names one. Replying to a member message sets an in-memory per-thread `BotRoomReplyTarget`, prepends `@handle ` when the draft does not already start with that handle (matched case-insensitively on the host's `[A-Za-z0-9._:-]` mention token so `@anna` does not suppress `@ann`), and focuses the composer. Because member bubbles keep `longPress: false` so `ResponseTextSelection` stays usable, Reply is exposed both in `BotMessageActions` (VoiceOver actions) and as a footer button in `ChatMessageMetaRow`. Cancelling the chip clears only the target and preserves whatever the user typed; user messages and unthreaded messages never offer member reply.

Lives in: `HermesMobile/Features/Bots/BotRoomReply.swift`, `HermesMobile/Features/Bots/BotRoomReader.swift`, `HermesMobile/Features/Bots/BotRoomView.swift`, `HermesMobile/Features/Bots/BotRoomComposerView.swift`
