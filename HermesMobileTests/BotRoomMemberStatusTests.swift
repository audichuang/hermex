import Observation
import XCTest
@testable import HermesMobile

@MainActor final class BotRoomMemberStatusTests: XCTestCase {
    func testFailedOutcomeUsesMappedReasonFreeTextFallbackOrBareLabel() {
        let events = [
            user(1),
            terminal(2, "turn.failed", member: "ada",
                     payload: ["reason_code": .string("provider_auth_or_access"), "error": .string("HTTP 401")]),
            terminal(3, "turn.failed", member: "linus",
                     payload: ["reason_code": .string("unknown"), "error": .string("Custom timeout\nstack trace")]),
            terminal(4, "turn.failed", member: "grace",
                     payload: ["reason_code": .string("unknown"), "error": .string("member turn failed")])
        ].compactMap(BotRoomEvent.init)

        let outcomes = BotRoomMemberOutcome.latest(in: events)
        XCTAssertEqual(outcomes["ada"], BotRoomMemberOutcome(kind: .failed, reasonCode: "provider_auth_or_access", detail: "HTTP 401"))
        XCTAssertEqual(BotRoomMemberOutcome.statusText(activity: nil, outcome: outcomes["ada"]),
                       "Failed: The provider refused access")
        XCTAssertEqual(BotRoomMemberOutcome.statusText(activity: nil, outcome: outcomes["linus"]),
                       "Failed: Custom timeout")
        XCTAssertEqual(BotRoomMemberOutcome.statusText(activity: nil, outcome: outcomes["grace"]),
                       "Failed")
    }

    func testDeferredOnlyCountsMemberUnavailableAndIgnoresOtherReasons() {
        let events = [
            user(1),
            terminal(2, "turn.deferred", member: "ada", payload: ["reason": .string("member_unavailable")]),
            terminal(3, "turn.deferred", member: "linus", payload: ["reason": .string("target_busy")]),
            terminal(4, "turn.failed", member: "grace", payload: ["reason_code": .string("runtime_offline")]),
            terminal(5, "turn.deferred", member: "grace", payload: ["reason": .string("target_busy")])
        ].compactMap(BotRoomEvent.init)

        let outcomes = BotRoomMemberOutcome.latest(in: events)
        XCTAssertEqual(outcomes["ada"], BotRoomMemberOutcome(kind: .unavailable))
        XCTAssertEqual(BotRoomMemberOutcome.statusText(activity: nil, outcome: outcomes["ada"]), "No answer")
        XCTAssertNil(outcomes["linus"])
        XCTAssertEqual(outcomes["grace"]?.kind, .failed, "ignored deferrals do not overwrite an existing outcome")
    }

    func testSettledAndCancelledOutcomesMapToDistinctLabels() {
        let events = [
            user(1),
            terminal(2, "turn.settled", member: "ada", payload: ["passed": .bool(true)]),
            terminal(3, "turn.settled", member: "linus", payload: ["passed": .bool(false)]),
            terminal(4, "turn.cancelled", member: "grace")
        ].compactMap(BotRoomEvent.init)

        let outcomes = BotRoomMemberOutcome.latest(in: events)
        XCTAssertEqual(outcomes["ada"], BotRoomMemberOutcome(kind: .passed))
        XCTAssertEqual(outcomes["linus"], BotRoomMemberOutcome(kind: .replied))
        XCTAssertEqual(outcomes["grace"], BotRoomMemberOutcome(kind: .cancelled))
        XCTAssertEqual(BotRoomMemberOutcome.statusText(activity: nil, outcome: outcomes["ada"]), "Skipped")
        XCTAssertEqual(BotRoomMemberOutcome.statusText(activity: nil, outcome: outcomes["linus"]), "Replied")
        XCTAssertEqual(BotRoomMemberOutcome.statusText(activity: nil, outcome: outcomes["grace"]), "Cancelled")
    }

    func testNewerUserMessageRetiresOldOutcomesOnlyInItsOwnThreadAndLaterTurnsWin() {
        let events = [
            user(1, thread: "t1"),
            terminal(2, "turn.failed", member: "ada", discussion: "user:1", thread: "t1",
                     payload: ["reason_code": .string("runtime_offline")]),
            terminal(3, "turn.settled", member: "linus", discussion: "user:1", thread: "t1",
                     payload: ["passed": .bool(false)]),
            user(4, thread: "t2"),
            terminal(5, "turn.settled", member: "grace", discussion: "user:4", thread: "t2",
                     payload: ["passed": .bool(true)]),
            user(6, thread: "t1"),
            terminal(7, "turn.settled", member: "linus", discussion: "user:6", thread: "t1",
                     payload: ["passed": .bool(true)]),
            terminal(8, "turn.settled", member: "linus", discussion: "user:6", thread: "t1",
                     payload: ["passed": .bool(false)])
        ].compactMap(BotRoomEvent.init)

        let outcomes = BotRoomMemberOutcome.latest(in: events)
        XCTAssertNil(outcomes["ada"], "a newer user message in t1 retires ada's failure from user:1")
        XCTAssertEqual(outcomes["grace"], BotRoomMemberOutcome(kind: .passed),
                       "a newer user message in t1 does not retire grace's outcome in t2")
        XCTAssertEqual(outcomes["linus"], BotRoomMemberOutcome(kind: .replied),
                       "a later event for the same member overwrites an earlier one")
    }

    func testLiveActivityOutranksOutcomeAndNilInputsProduceNil() throws {
        let failed = BotRoomMemberOutcome(kind: .failed, reasonCode: "runtime_offline")
        let runningWithTool = try XCTUnwrap(BotRoomMemberActivity(.object([
            "member_id": .string("ada"), "status": .string("running"), "tool": .string("web_search")
        ])))
        let runningPlain = try XCTUnwrap(BotRoomMemberActivity(.object([
            "member_id": .string("ada"), "status": .string("running")
        ])))
        let queued = try XCTUnwrap(BotRoomMemberActivity(.object([
            "member_id": .string("ada"), "status": .string("queued")
        ])))
        let stopping = try XCTUnwrap(BotRoomMemberActivity(.object([
            "member_id": .string("ada"), "status": .string("stopping")
        ])))

        XCTAssertEqual(BotRoomMemberOutcome.statusText(activity: runningWithTool, outcome: failed), "Working · web_search")
        XCTAssertEqual(BotRoomMemberOutcome.statusText(activity: runningPlain, outcome: failed), "Working")
        XCTAssertEqual(BotRoomMemberOutcome.statusText(activity: queued, outcome: failed), "Queued")
        XCTAssertEqual(BotRoomMemberOutcome.statusText(activity: stopping, outcome: failed), "Stopping…")
        XCTAssertNil(BotRoomMemberOutcome.statusText(activity: nil, outcome: nil))
        XCTAssertEqual(BotRoomMemberOutcome.activeActivity(for: "ada", in: [queued, stopping, runningPlain]), runningPlain)
        XCTAssertEqual(BotRoomMemberOutcome.activeActivity(for: "ada", in: [queued, stopping]), stopping)
        XCTAssertEqual(BotRoomMemberOutcome.activeActivity(for: "ada", in: [queued]), queued)
        XCTAssertNil(BotRoomMemberOutcome.activeActivity(for: "linus", in: [queued]))
    }

    func testReaderDerivesOutcomesFromRoundEventsAndUnchangedPollDoesNotReassign() async throws {
        let wire = RoomWire()
        wire.members = [
            .object(["member_id": .string("ada"), "display_name": .string("Ada"), "handle": .string("ada")]),
            .object(["member_id": .string("linus"), "display_name": .string("Linus"), "handle": .string("linus")])
        ]
        wire.latest = 3
        wire.roomEvents = [
            1: user(1),
            2: terminal(2, "turn.settled", member: "ada", payload: ["passed": .bool(false)]),
            3: terminal(3, "turn.failed", member: "linus", payload: ["reason_code": .string("runtime_offline")])
        ]

        let server = try XCTUnwrap(URL(string: "https://room-fixture.example"))
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: wire.latest)))
        let key = BotRoomKey(server: server, connectionID: connection.id, roomID: room.id)
        let reader = BotRoomReader(key: key, connection: connection, room: room, cache: BotHistoryCache(), makeWire: { _ in wire })
        defer { reader.close() }
        await reader.open()

        XCTAssertEqual(reader.memberOutcomes["ada"], BotRoomMemberOutcome(kind: .replied))
        XCTAssertEqual(reader.memberOutcomes["linus"], BotRoomMemberOutcome(kind: .failed, reasonCode: "runtime_offline"))

        let changed = expectation(description: "memberOutcomes were reassigned")
        withObservationTracking { _ = reader.memberOutcomes } onChange: { changed.fulfill() }

        await reader.poll()
        wire.latest = 4
        wire.roomEvents[4] = event(4, "room.activity", payload: [
            "status": .string("settled"), "discussion_event_id": .string("user:1"), "thread_id": .string("t1")
        ])
        await reader.poll()

        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0), .timedOut)
    }

    private func user(_ seq: Int, thread: String = "t1") -> BotJSON {
        event(seq, "message.user", eventID: "user:\(seq)", payload: [
            "text": .string("Prompt \(seq)"), "thread_id": .string(thread)
        ])
    }

    private func terminal(_ seq: Int, _ kind: String, member: String, discussion: String = "user:1",
                          thread: String = "t1", payload: [String: BotJSON] = [:]) -> BotJSON {
        var fields = payload
        fields["member_id"] = .string(member)
        fields["discussion_event_id"] = .string(discussion)
        fields["thread_id"] = .string(thread)
        return event(seq, kind, payload: fields)
    }

    private func event(_ seq: Int, _ kind: String, eventID: String? = nil, payload: [String: BotJSON]) -> BotJSON {
        var fields = RoomFixture.event(seq, kind: kind).fields!
        fields["event_id"] = eventID.map(BotJSON.string)
        fields["payload"] = .object(payload)
        return .object(fields)
    }
}
