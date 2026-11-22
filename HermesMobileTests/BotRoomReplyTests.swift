import XCTest
@testable import HermesMobile

@MainActor final class BotRoomReplyTests: XCTestCase {
    func testAddressingPrependsHandleWithoutDuplicatingExistingMention() {
        XCTAssertEqual(BotRoomReplyTarget.addressing("", to: "ada"), "@ada ")
        XCTAssertEqual(BotRoomReplyTarget.addressing("please check", to: "ada"), "@ada please check")
        XCTAssertEqual(BotRoomReplyTarget.addressing("@ada ", to: "ada"), "@ada ")
        XCTAssertEqual(BotRoomReplyTarget.addressing("@ada please check", to: "ada"), "@ada please check")
        XCTAssertEqual(BotRoomReplyTarget.addressing("  @Ada please check", to: "ada"), "  @Ada please check")
        XCTAssertEqual(BotRoomReplyTarget.addressing("@ann, check this", to: "ann"), "@ann, check this")
        XCTAssertEqual(BotRoomReplyTarget.addressing("@anna please check", to: "ann"), "@ann @anna please check",
                       "a longer handle sharing the same prefix must not block addressing")
    }

    func testMemberWithoutHandleSetsTargetChipWithoutChangingDraft() throws {
        let room = makeRoom([
            (id: "ada", name: "Ada", handle: nil)
        ])
        let reader = makeReader(wire: RoomWire(), room: room)
        reader.setDraft("keep my text", in: "thread")
        let replyEvent = try XCTUnwrap(BotRoomEvent(memberMessage(2, from: "ada", text: "\n  First line\nSecond line", threadID: "thread")))

        reader.beginReply(to: replyEvent, in: "thread")

        XCTAssertEqual(reader.replyTarget(in: "thread"), BotRoomReplyTarget(name: "Ada", handle: nil, excerpt: "First line"))
        XCTAssertEqual(reader.draft(in: "thread"), "keep my text")
    }

    func testSendAddressesMemberInSameThreadAndClearsReplyTarget() async throws {
        let wire = RoomWire()
        wire.members = [
            .object(["member_id": .string("ada"), "display_name": .string("Ada"), "handle": .string("ada")]),
            .object(["member_id": .string("linus"), "display_name": .string("Linus"), "handle": .string("linus")])
        ]
        wire.latest = 2
        wire.roomEvents = [
            1: userMessage(1, text: "Start", threadID: "thread-1"),
            2: memberMessage(2, from: "ada", text: "Here is my update\nMore detail", threadID: "thread-1")
        ]
        let room = makeRoom([
            (id: "ada", name: "Ada", handle: "ada"),
            (id: "linus", name: "Linus", handle: "linus")
        ])
        let reader = makeReader(wire: wire, room: room)
        defer { reader.close() }
        await reader.open()

        let memberEvent = try XCTUnwrap(reader.events.first { $0.seq == 2 })
        reader.beginReply(to: memberEvent, in: "thread-1")
        XCTAssertEqual(reader.replyTarget(in: "thread-1"),
                       BotRoomReplyTarget(name: "Ada", handle: "ada", excerpt: "Here is my update"))
        XCTAssertEqual(reader.draft(in: "thread-1"), "@ada ")

        reader.setDraft(reader.draft(in: "thread-1") + "follow up", in: "thread-1")
        await reader.send(threadID: "thread-1")

        XCTAssertNil(reader.replyTarget(in: "thread-1"))
        let sent = try XCTUnwrap(wire.writes.last { $0.0 == "groups.send" })
        XCTAssertEqual(sent.1["payload"]?["thread_id"].text, "thread-1")
        XCTAssertEqual(sent.1["payload"]?["text"].text, "@ada follow up")
    }

    func testCancelReplyPreservesUserDraftText() throws {
        let room = makeRoom([(id: "ada", name: "Ada", handle: "ada")])
        let reader = makeReader(wire: RoomWire(), room: room)
        let memberEvent = try XCTUnwrap(BotRoomEvent(memberMessage(2, from: "ada", text: "Status ok", threadID: "thread-1")))

        reader.beginReply(to: memberEvent, in: "thread-1")
        reader.setDraft(reader.draft(in: "thread-1") + "can you double check?", in: "thread-1")
        reader.cancelReply(in: "thread-1")

        XCTAssertNil(reader.replyTarget(in: "thread-1"))
        XCTAssertEqual(reader.draft(in: "thread-1"), "@ada can you double check?")
    }

    func testSwitchingReplyTargetReplacesPreviouslyInsertedHandle() throws {
        let room = makeRoom([
            (id: "ada", name: "Ada", handle: "ada"),
            (id: "linus", name: "Linus", handle: "linus"),
            (id: "nora", name: "Nora", handle: nil)
        ])
        let reader = makeReader(wire: RoomWire(), room: room)
        let adaEvent = try XCTUnwrap(BotRoomEvent(memberMessage(2, from: "ada", text: "Ada update", threadID: "thread-1")))
        let linusEvent = try XCTUnwrap(BotRoomEvent(memberMessage(3, from: "linus", text: "Linus update", threadID: "thread-1")))
        let noraEvent = try XCTUnwrap(BotRoomEvent(memberMessage(4, from: "nora", text: "Nora update", threadID: "thread-1")))

        reader.setDraft("please review", in: "thread-1")
        reader.beginReply(to: adaEvent, in: "thread-1")
        XCTAssertEqual(reader.draft(in: "thread-1"), "@ada please review")

        reader.beginReply(to: linusEvent, in: "thread-1")
        XCTAssertEqual(reader.replyTarget(in: "thread-1"), BotRoomReplyTarget(name: "Linus", handle: "linus", excerpt: "Linus update"))
        XCTAssertEqual(reader.draft(in: "thread-1"), "@linus please review")

        reader.beginReply(to: noraEvent, in: "thread-1")
        XCTAssertEqual(reader.replyTarget(in: "thread-1"), BotRoomReplyTarget(name: "Nora", handle: nil, excerpt: "Nora update"))
        XCTAssertEqual(reader.draft(in: "thread-1"), "please review")

        reader.beginReply(to: adaEvent, in: "thread-2")
        reader.beginReply(to: linusEvent, in: "thread-2")
        XCTAssertEqual(reader.draft(in: "thread-2"), "@linus ")

        reader.setDraft("@ada please check", in: "thread-3")
        reader.beginReply(to: linusEvent, in: "thread-3")
        XCTAssertEqual(reader.draft(in: "thread-3"), "@linus @ada please check",
                       "a mention typed by the user must not be stripped when replying to another member")
    }

    func testCancelReplyThenReplyToAnotherMemberReplacesInsertedHandle() throws {
        let room = makeRoom([
            (id: "ada", name: "Ada", handle: "ada"),
            (id: "linus", name: "Linus", handle: "linus")
        ])
        let reader = makeReader(wire: RoomWire(), room: room)
        let adaEvent = try XCTUnwrap(BotRoomEvent(memberMessage(2, from: "ada", text: "Ada update", threadID: "thread-1")))
        let linusEvent = try XCTUnwrap(BotRoomEvent(memberMessage(3, from: "linus", text: "Linus update", threadID: "thread-1")))

        reader.beginReply(to: adaEvent, in: "thread-1")
        reader.setDraft(reader.draft(in: "thread-1") + "can you check?", in: "thread-1")
        reader.cancelReply(in: "thread-1")
        XCTAssertNil(reader.replyTarget(in: "thread-1"))
        XCTAssertEqual(reader.draft(in: "thread-1"), "@ada can you check?")

        reader.beginReply(to: linusEvent, in: "thread-1")
        XCTAssertEqual(reader.replyTarget(in: "thread-1"), BotRoomReplyTarget(name: "Linus", handle: "linus", excerpt: "Linus update"))
        XCTAssertEqual(reader.draft(in: "thread-1"), "@linus can you check?")

        reader.cancelReply(in: "thread-1")
        reader.setDraft("", in: "thread-1")
        reader.setDraft("@linus manual note", in: "thread-1")
        reader.beginReply(to: adaEvent, in: "thread-1")
        XCTAssertEqual(reader.draft(in: "thread-1"), "@ada @linus manual note",
                       "clearing the draft forgets the previously inserted handle")
    }

    func testBeginReplyIgnoresUserMessagesAndKeepsThreadsSeparate() throws {
        let room = makeRoom([(id: "ada", name: "Ada", handle: "ada")])
        let reader = makeReader(wire: RoomWire(), room: room)
        let userEvent = try XCTUnwrap(BotRoomEvent(userMessage(1, text: "My message", threadID: "thread-1")))
        let memberEvent = try XCTUnwrap(BotRoomEvent(memberMessage(2, from: "ada", text: "Answer", threadID: "thread-1")))

        reader.beginReply(to: userEvent, in: "thread-1")
        XCTAssertNil(reader.replyTarget(in: "thread-1"))

        reader.beginReply(to: memberEvent, in: "thread-1")
        XCTAssertNotNil(reader.replyTarget(in: "thread-1"))
        XCTAssertNil(reader.replyTarget(in: "thread-2"))
    }

    func testBeginReplyIsBlockedWhileDictatingAndAllowedAfterward() throws {
        let room = makeRoom([(id: "ada", name: "Ada", handle: "ada")])
        let reader = makeReader(wire: RoomWire(), room: room)
        let adaEvent = try XCTUnwrap(BotRoomEvent(memberMessage(2, from: "ada", text: "Ada update", threadID: "thread-1")))

        reader.setDraft("in progress", in: "thread-1")
        reader.setDictating(true, in: "thread-1")
        XCTAssertFalse(reader.mayReply(in: "thread-1"))
        XCTAssertTrue(reader.mayReply(in: "thread-2"))

        reader.beginReply(to: adaEvent, in: "thread-1")
        XCTAssertNil(reader.replyTarget(in: "thread-1"))
        XCTAssertEqual(reader.draft(in: "thread-1"), "in progress")

        reader.setDictating(false, in: "thread-1")
        XCTAssertTrue(reader.mayReply(in: "thread-1"))

        reader.beginReply(to: adaEvent, in: "thread-1")
        XCTAssertEqual(reader.replyTarget(in: "thread-1"), BotRoomReplyTarget(name: "Ada", handle: "ada", excerpt: "Ada update"))
        XCTAssertEqual(reader.draft(in: "thread-1"), "@ada in progress")
    }

    func testRemovingLeadingMentionClearsReplyTarget() throws {
        let room = makeRoom([
            (id: "ada", name: "Ada", handle: "ada"),
            (id: "nora", name: "Nora", handle: nil)
        ])
        let reader = makeReader(wire: RoomWire(), room: room)
        let adaEvent = try XCTUnwrap(BotRoomEvent(memberMessage(2, from: "ada", text: "Ada update", threadID: "thread-1")))
        let noraEvent = try XCTUnwrap(BotRoomEvent(memberMessage(3, from: "nora", text: "Nora update", threadID: "thread-4")))

        reader.beginReply(to: adaEvent, in: "thread-1")
        XCTAssertNotNil(reader.replyTarget(in: "thread-1"))
        reader.setDraft("hello", in: "thread-1")
        XCTAssertNil(reader.replyTarget(in: "thread-1"))

        reader.setDraft("@ada hi", in: "thread-2")
        reader.beginReply(to: adaEvent, in: "thread-2")
        XCTAssertNotNil(reader.replyTarget(in: "thread-2"))
        XCTAssertEqual(reader.draft(in: "thread-2"), "@ada hi")
        reader.setDraft("hi", in: "thread-2")
        XCTAssertNil(reader.replyTarget(in: "thread-2"))

        reader.beginReply(to: adaEvent, in: "thread-3")
        reader.setDraft("@ada follow up", in: "thread-3")
        XCTAssertNotNil(reader.replyTarget(in: "thread-3"))

        reader.beginReply(to: noraEvent, in: "thread-4")
        reader.setDraft("hello", in: "thread-4")
        XCTAssertEqual(reader.replyTarget(in: "thread-4"), BotRoomReplyTarget(name: "Nora", handle: nil, excerpt: "Nora update"))
    }

    func testBotMessageActionsIncludesReplyWhenProvided() {
        var replied = false
        let withReply = BotMessageActions.items(copyText: "Hello", isHapticsEnabled: false, reply: { replied = true })
        XCTAssertEqual(withReply.map(\.kind), [.reply, .copy])
        withReply.first?.perform()
        XCTAssertTrue(replied)

        let fileOnlyReply = BotMessageActions.items(copyText: "", isHapticsEnabled: false, reply: {})
        XCTAssertEqual(fileOnlyReply.map(\.kind), [.reply])

        let withoutReply = BotMessageActions.items(copyText: "Hello", isHapticsEnabled: false)
        XCTAssertEqual(withoutReply.map(\.kind), [.copy])
    }

    private func makeReader(wire: RoomWire, room: BotGroupRoom) -> BotRoomReader {
        let server = URL(string: "https://room-fixture.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let key = BotRoomKey(server: server, connectionID: connection.id, roomID: room.id)
        return BotRoomReader(key: key, connection: connection, room: room, cache: BotHistoryCache(), makeWire: { _ in wire })
    }

    private func makeRoom(_ specs: [(id: String, name: String, handle: String?)]) -> BotGroupRoom {
        BotGroupRoom(.object([
            "room_id": .string("fixture-room"), "name": .string("Comms"), "latest_seq": .number(0),
            "authority_gateway_id": .string("fixture-install"), "authority_epoch": .number(1),
            "members": .array(specs.map { spec in
                var fields: [String: BotJSON] = [
                    "member_id": .string(spec.id),
                    "display_name": .string(spec.name)
                ]
                if let handle = spec.handle { fields["handle"] = .string(handle) }
                return .object(fields)
            })
        ]))!
    }

    private func userMessage(_ seq: Int, text: String, threadID: String) -> BotJSON {
        var fields = RoomFixture.event(seq, kind: "message.user").fields!
        fields["payload"] = .object(["text": .string(text), "thread_id": .string(threadID)])
        return .object(fields)
    }

    private func memberMessage(_ seq: Int, from memberID: String, text: String, threadID: String) -> BotJSON {
        var fields = RoomFixture.event(seq, kind: "message.member").fields!
        fields["actor"] = .object(["kind": .string("member"), "id": .string(memberID)])
        fields["payload"] = .object([
            "member_id": .string(memberID),
            "text": .string(text),
            "thread_id": .string(threadID)
        ])
        return .object(fields)
    }
}
