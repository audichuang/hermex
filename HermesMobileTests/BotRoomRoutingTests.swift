import Observation
import XCTest
@testable import HermesMobile

@MainActor final class BotRoomRoutingTests: XCTestCase {
    func testAssignmentTextCoversLeadPicksAndFallback() throws {
        let room = makeRoom()
        let picked = try XCTUnwrap(BotRoomEvent(event(2, "room.assignment", payload: [
            "discussion_event_id": .string("user:1"), "thread_id": .string("thread"), "task_id": .string("dtask:1"),
            "lead_member_id": .string("ada"), "member_ids": .array([.string("linus"), .string("grace")]),
            "fallback": .bool(false)
        ])))
        let pickedText = try XCTUnwrap(picked.routingText(in: room))
        XCTAssertTrue(pickedText.contains("Ada"))
        XCTAssertTrue(pickedText.contains("Linus"))
        XCTAssertTrue(pickedText.contains("Grace"))

        let fallback = try XCTUnwrap(BotRoomEvent(event(3, "room.assignment", payload: [
            "discussion_event_id": .string("user:1"), "thread_id": .string("thread"), "task_id": .string("dtask:1"),
            "lead_member_id": .string("ada"), "member_ids": .array([.string("ada")]),
            "fallback": .bool(true)
        ])))
        let fallbackText = try XCTUnwrap(fallback.routingText(in: room))
        XCTAssertTrue(fallbackText.contains("Ada"))
        XCTAssertNotEqual(fallbackText, pickedText)
    }

    func testRoutedTextCoversNamedMembersEveryoneFallbackAndDepartedRoster() throws {
        let room = makeRoom()
        let named = try XCTUnwrap(BotRoomEvent(event(2, "room.routed", payload: [
            "discussion_event_id": .string("user:1"), "thread_id": .string("thread"),
            "member_ids": .array([.string("linus"), .string("departed"), .string("grace")]),
            "everyone": .bool(false), "fallback": .bool(false)
        ])))
        let namedText = try XCTUnwrap(named.routingText(in: room))
        XCTAssertTrue(namedText.contains("Linus"))
        XCTAssertTrue(namedText.contains("Grace"))
        XCTAssertFalse(namedText.contains("departed"))

        let everyone = try XCTUnwrap(BotRoomEvent(event(3, "room.routed", payload: [
            "discussion_event_id": .string("user:1"), "thread_id": .string("thread"),
            "member_ids": .array([]), "everyone": .bool(true), "fallback": .bool(false)
        ])))
        let everyoneText = try XCTUnwrap(everyone.routingText(in: room))
        XCTAssertFalse(everyoneText.isEmpty)

        let fallback = try XCTUnwrap(BotRoomEvent(event(4, "room.routed", payload: [
            "discussion_event_id": .string("user:1"), "thread_id": .string("thread"),
            "member_ids": .array([]), "everyone": .bool(true), "fallback": .bool(true)
        ])))
        let fallbackText = try XCTUnwrap(fallback.routingText(in: room))
        XCTAssertFalse(fallbackText.isEmpty)
        XCTAssertNotEqual(fallbackText, everyoneText)

        let allGone = try XCTUnwrap(BotRoomEvent(event(5, "room.routed", payload: [
            "discussion_event_id": .string("user:1"), "thread_id": .string("thread"),
            "member_ids": .array([.string("departed")]), "everyone": .bool(false), "fallback": .bool(false)
        ])))
        XCTAssertNil(allGone.routingText(in: room))
    }

    func testHandoffMatchesFollowingTurnInSameDiscussionAndExcludesNonMatches() throws {
        let room = makeRoom([
            ("ada", "Ada", "ann"),
            ("linus", "Linus", "anna"),
            ("grace", "Grace", "grace")
        ])
        let history = [
            memberMessage(2, from: "ada", text: "Looping in @grace on this.", discussion: "user:1"),
            terminal(3, "turn.settled", member: "grace", discussion: "user:1"),
            memberMessage(4, from: "grace", text: "Checking @grace myself.", discussion: "user:1"),
            terminal(5, "turn.settled", member: "grace", discussion: "user:1"),
            memberMessage(6, from: "ada", text: "Maybe @anna later.", discussion: "user:1"),
            terminal(7, "turn.settled", member: "linus", discussion: "user:2"),
            memberMessage(8, from: "linus", text: "Ping @grace without a follow-up.", discussion: "user:2"),
            memberMessage(9, from: "grace", text: "Hi @anna, take a look.", discussion: "user:3"),
            terminal(10, "turn.deferred", member: "ada", discussion: "user:3"),
            terminal(11, "turn.failed", member: "linus", discussion: "user:3"),
            memberMessage(12, from: "grace", text: "Ask @anna and email@ann or @@ann.", discussion: "user:4"),
            terminal(13, "turn.cancelled", member: "ada", discussion: "user:4"),
            memberMessage(14, from: "ada", text: "Restored @grace without discussion id.", discussion: nil),
            terminal(15, "turn.settled", member: "grace", discussion: "user:4"),
            memberMessage(16, from: "linus", text: "請@ann幫忙看一下", discussion: "user:5"),
            terminal(17, "turn.deferred", member: "ada", discussion: "user:5")
        ].compactMap(BotRoomEvent.init)

        let handoffs = BotRoomHandoffs.find(in: history, members: room.members)
        XCTAssertEqual(handoffs[2], [BotRoomHandoff(afterSeq: 2, from: "ada", to: "grace")])
        XCTAssertNil(handoffs[4], "mentioning self does not produce a handoff")
        XCTAssertNil(handoffs[6], "a turn in another discussion does not satisfy the mention")
        XCTAssertNil(handoffs[8], "a mention with no subsequent turn produces no handoff")
        XCTAssertEqual(handoffs[9], [BotRoomHandoff(afterSeq: 9, from: "grace", to: "linus")],
                       "@anna does not match prefix handle @ann when @ann is also followed by a turn")
        let prefixOnly = [
            memberMessage(20, from: "grace", text: "Only @anna and @ann-2 here.", discussion: "user:6"),
            terminal(21, "turn.settled", member: "ada", discussion: "user:6")
        ].compactMap(BotRoomEvent.init)
        XCTAssertTrue(BotRoomHandoffs.find(in: prefixOnly, members: room.members).isEmpty)
        XCTAssertNil(handoffs[12], "word char or @ before @handle does not match")
        XCTAssertNil(handoffs[14], "restored messages without discussion_event_id never produce handoffs")
        XCTAssertEqual(handoffs[16], [BotRoomHandoff(afterSeq: 16, from: "linus", to: "ada")])
        let label = try XCTUnwrap(handoffs[2]?.first).text(in: room)
        XCTAssertTrue(label.contains("Ada") && label.contains("Grace"))
    }

    func testAutoRoomActivityStripUsesRoutedSeats() throws {
        let room = makeRoom()
        let user = try XCTUnwrap(BotRoomEvent(event(1, "message.user", eventID: "user:1", payload: [
            "text": .string("Check this"), "thread_id": .string("thread")
        ])))
        let picked = try XCTUnwrap(BotRoomEvent(event(2, "room.routed", payload: [
            "discussion_event_id": .string("user:1"), "thread_id": .string("thread"),
            "member_ids": .array([.string("linus"), .string("grace")]),
            "everyone": .bool(false), "fallback": .bool(false)
        ])))
        let running = try XCTUnwrap(BotRoomMemberActivity(.object([
            "member_id": .string("linus"), "status": .string("running"),
            "thread_id": .string("thread"), "started_at": .number(1_000)
        ])))
        let narrow = try XCTUnwrap(BotRoomRound.build(events: [user, picked], activity: [running], room: room, threadID: nil))
        XCTAssertEqual(narrow.seats.map(\.memberID), ["linus", "grace"])

        let everyone = try XCTUnwrap(BotRoomEvent(event(3, "room.routed", payload: [
            "discussion_event_id": .string("user:1"), "thread_id": .string("thread"),
            "member_ids": .array([]), "everyone": .bool(true), "fallback": .bool(false)
        ])))
        let all = try XCTUnwrap(BotRoomRound.build(events: [user, everyone], activity: [running], room: room, threadID: nil))
        XCTAssertEqual(all.seats.map(\.memberID), ["linus", "ada", "grace"])
    }

    func testReaderPublishesRoutingOnceFiltersEmptyRoutedAndAvoidsStaleHandoffReassignment() async throws {
        let wire = RoomWire()
        wire.members = [
            .object(["member_id": .string("ada"), "display_name": .string("Ada"), "handle": .string("ada")]),
            .object(["member_id": .string("linus"), "display_name": .string("Linus"), "handle": .string("linus")])
        ]
        wire.latest = 5
        wire.roomEvents = [
            1: event(1, "message.user", eventID: "user:1", payload: ["text": .string("Start"), "thread_id": .string("thread")]),
            2: event(2, "room.assignment", payload: [
                "discussion_event_id": .string("user:1"), "thread_id": .string("thread"), "task_id": .string("dtask:route"),
                "lead_member_id": .string("ada"), "member_ids": .array([.string("ada")]), "fallback": .bool(false)
            ]),
            3: event(3, "room.routed", payload: [
                "discussion_event_id": .string("user:1"), "thread_id": .string("thread"),
                "member_ids": .array([.string("departed")]), "everyone": .bool(false), "fallback": .bool(false)
            ]),
            4: memberMessage(4, from: "ada", text: "Handing off to @linus.", discussion: "user:1"),
            5: terminal(5, "turn.settled", member: "linus", discussion: "user:1")
        ]

        let server = try XCTUnwrap(URL(string: "https://room-fixture.example"))
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let room = makeRoom([("ada", "Ada", "ada"), ("linus", "Linus", "linus")])
        let key = BotRoomKey(server: server, connectionID: connection.id, roomID: room.id)
        let reader = BotRoomReader(key: key, connection: connection, room: room, cache: BotHistoryCache(), makeWire: { _ in wire })
        defer { reader.close() }
        await reader.open()

        XCTAssertEqual(reader.events.map(\.seq), [1, 2, 4], "empty routed event is filtered out")
        XCTAssertEqual(reader.roundEvents.filter { $0.kind == "room.assignment" }.map(\.seq), [2],
                       "room.assignment appears once in roundEvents")
        XCTAssertEqual(reader.handoffs, [4: [BotRoomHandoff(afterSeq: 4, from: "ada", to: "linus")]])

        let changed = expectation(description: "handoffs were reassigned")
        withObservationTracking { _ = reader.handoffs } onChange: { changed.fulfill() }

        await reader.poll()
        wire.latest = 6
        wire.roomEvents[6] = event(6, "room.activity", payload: [
            "status": .string("settled"), "discussion_event_id": .string("user:1"), "thread_id": .string("thread")
        ])
        await reader.poll()

        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0), .timedOut)
    }

    private func makeRoom(_ specs: [(id: String, name: String, handle: String)] = [
        ("ada", "Ada", "ada"), ("linus", "Linus", "linus"), ("grace", "Grace", "grace")
    ]) -> BotGroupRoom {
        BotGroupRoom(.object([
            "room_id": .string("fixture-room"), "name": .string("Comms"), "latest_seq": .number(0),
            "authority_gateway_id": .string("fixture-install"), "authority_epoch": .number(1),
            "members": .array(specs.map {
                .object(["member_id": .string($0.id), "display_name": .string($0.name), "handle": .string($0.handle)])
            })
        ]))!
    }

    private func memberMessage(_ seq: Int, from: String, text: String, discussion: String?) -> BotJSON {
        var payload: [String: BotJSON] = [
            "member_id": .string(from), "text": .string(text), "thread_id": .string("thread")
        ]
        payload["discussion_event_id"] = discussion.map(BotJSON.string)
        return event(seq, "message.member", actor: ["kind": .string("member"), "id": .string(from)], payload: payload)
    }

    private func terminal(_ seq: Int, _ kind: String, member: String, discussion: String) -> BotJSON {
        event(seq, kind, payload: [
            "member_id": .string(member), "discussion_event_id": .string(discussion), "thread_id": .string("thread")
        ])
    }

    private func event(_ seq: Int, _ kind: String, eventID: String? = nil, actor: [String: BotJSON]? = nil,
                       payload: [String: BotJSON]) -> BotJSON {
        var fields = RoomFixture.event(seq, kind: kind).fields!
        fields["event_id"] = eventID.map(BotJSON.string)
        if let actor { fields["actor"] = .object(actor) }
        fields["payload"] = .object(payload)
        return .object(fields)
    }
}
