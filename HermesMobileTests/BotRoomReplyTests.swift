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
