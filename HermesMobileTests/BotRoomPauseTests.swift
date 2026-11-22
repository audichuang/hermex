import Observation
import XCTest
@testable import HermesMobile

@MainActor final class BotRoomPauseTests: XCTestCase {
    func testLatestBoundedEventCountsOnlyItsDiscussionMessagesBeforeThePause() {
        let pauses = pauses(in: [
            user(1), event(2, "message.member"), event(3, "message.member", discussion: "another"),
            event(4, "message.member"), bounded(5), event(6, "message.member")
        ])
        XCTAssertEqual(pauses[5], BotRoomPause(count: 2, actionable: true, discussionEventID: "user:1"))
    }

    func testStopAfterBoundedEventRetiresThePause() {
        let pauses = pauses(in: [user(1), bounded(2), stop(3)])
        XCTAssertEqual(pauses[2]?.actionable, false)
    }

    func testStopAfterTheSourceButBeforeBoundedEventRetiresThePause() {
        let pauses = pauses(in: [user(1), stop(2), bounded(3)])
        XCTAssertEqual(pauses[3]?.actionable, false)
    }

    func testTheSameStopRetiresPausesInDifferentThreads() {
        let pauses = pauses(in: [
            user(1), user(2, thread: "other"), bounded(3),
            bounded(4, discussion: "user:2", thread: "other"), stop(5)
        ])
        XCTAssertEqual(pauses[3]?.actionable, false)
        XCTAssertEqual(pauses[4]?.actionable, false)
    }

    func testNewMessageInTheSameThreadAfterBoundedEventRetiresThePause() {
        let pauses = pauses(in: [user(1), bounded(2), user(3)])
        XCTAssertEqual(pauses[2]?.actionable, false)
    }

    func testNewMessageAfterTheSourceButBeforeBoundedEventRetiresThePause() {
        let pauses = pauses(in: [user(1), user(2), bounded(3)])
        XCTAssertEqual(pauses[3]?.actionable, false)
    }

    func testMissingSourceUsesTheBoundedSequenceAsTheFence() {
        let history = [stop(10), user(11), bounded(12)]
        XCTAssertEqual(pauses(in: history)[12]?.actionable, true)
        XCTAssertEqual(pauses(in: history + [stop(13)])[12]?.actionable, false)
    }

    func testContinueOrLaterBoundedEventRetiresThePreviousPause() {
        let history = [user(1), bounded(2)]
        XCTAssertEqual(pauses(in: history + [event(3, "room.continued")])[2]?.actionable, false)
        let afterNewPause = pauses(in: history + [bounded(3)])
        XCTAssertEqual(afterNewPause[2]?.actionable, false)
        XCTAssertEqual(afterNewPause[3]?.actionable, true)
    }

    func testPauseBecomesReadOnlyAtTheHostsContinueLimit() {
        let history = [user(1)] + (2...6).map { event($0, "room.continued") } + [bounded(7)]
        XCTAssertEqual(pauses(in: history, limit: 5)[7]?.actionable, false)
        XCTAssertEqual(pauses(in: history, limit: 6)[7]?.actionable, true)
    }

    func testContinueGrantRetiresPauseWhenEarlierContinuesAreOutsideTheWindow() {
        let history = [
            event(50, "room.continued", payload: ["grant": .number(5)]),
            bounded(51)
        ]
        XCTAssertEqual(pauses(in: history, limit: 5)[51]?.actionable, false)
        XCTAssertEqual(pauses(in: history, limit: 6)[51]?.actionable, true)

        let nonIntegerGrant = [
            event(60, "room.continued", payload: ["grant": .string("5")]),
            event(61, "room.continued", payload: ["grant": .number(5.5)]),
            bounded(62)
        ]
        XCTAssertEqual(pauses(in: nonIntegerGrant, limit: 5)[62]?.actionable, true)
        XCTAssertEqual(pauses(in: nonIntegerGrant, limit: 2)[62]?.actionable, false)
    }

    func testMemberMessagesWithoutADiscussionIDDoNotCount() {
        let pauses = pauses(in: [
            user(1), event(2, "message.member", discussion: nil), event(3, "message.member"), bounded(4)
        ])
        XCTAssertEqual(pauses[4]?.count, 1)
    }

    func testContinueSendsTheTwoIDsAndRetiresThePauseWithoutDuplicatingTheReceipt() async throws {
        let wire = RoomWire()
        let reader = try await openPausedRoom(wire)
        defer { reader.close() }
        XCTAssertEqual(reader.pausedThreadIDs, ["thread"])

        await reader.continueDiscussion("user:1")

        XCTAssertEqual(wire.writes.map(\.0), ["groups.continue"])
        XCTAssertEqual(wire.writes.first?.1, ["room_id": .string("fixture-room"), "discussion_event_id": .string("user:1")])
        XCTAssertEqual(reader.pauses[2]?.actionable, false)
        XCTAssertTrue(reader.pausedThreadIDs.isEmpty)
        await reader.poll()
        XCTAssertEqual(reader.events.filter { $0.kind == "room.continued" }.map(\.seq), [3])
        XCTAssertEqual(reader.roundEvents.filter { $0.kind == "room.continued" }.map(\.seq), [3])
        XCTAssertEqual(wire.logStarts.last, 2)
    }

    func testRejectedContinueRefreshesThePauseFromTheServer() async throws {
        let wire = RoomWire()
        let reader = try await openPausedRoom(wire)
        defer { reader.close() }
        wire.writeFailure = BotRoomFailure(code: 4001, reason: "invalid_params")
        wire.latest = 3
        wire.roomEvents[3] = stop(3)
        let refreshed = expectation(description: "continue rejection refreshes the pause")
        withObservationTracking { _ = reader.pausedThreadIDs } onChange: { refreshed.fulfill() }

        await reader.continueDiscussion("user:1")
        await fulfillment(of: [refreshed], timeout: 2)

        XCTAssertEqual(wire.writes.map(\.0), ["groups.continue"])
        XCTAssertNotNil(reader.commandMessage)
        XCTAssertEqual(reader.pauses[2]?.actionable, false)
    }

    func testMissingContinueMethodOrLimitLeavesOnlyTheWorkLimitNotice() async throws {
        for (advertisesContinue, limit) in [(false, 5), (true, nil)] as [(Bool, Int?)] {
            let wire = RoomWire()
            let reader = try await openPausedRoom(wire, advertisesContinue: advertisesContinue, limit: limit)
            defer { reader.close() }
            XCTAssertEqual(reader.events.last?.kind, "room.activity")
            XCTAssertNil(reader.pauses[2])
            XCTAssertFalse(reader.mayContinue)
            XCTAssertTrue(reader.pausedThreadIDs.isEmpty)
            await reader.continueDiscussion("user:1")
            XCTAssertTrue(wire.writes.isEmpty)
        }
    }

    func testIdleStopSendsTheRoomCommandAndAcceptsZeroCancelled() async throws {
        let wire = RoomWire()
        let reader = try await openPausedRoom(wire)
        defer { reader.close() }
        XCTAssertFalse(reader.mayStop)
        XCTAssertTrue(reader.mayStopPaused)
        XCTAssertFalse(reader.pausedStopNeedsConfirmation)
        let refreshed = expectation(description: "stop refreshes the pause")
        withObservationTracking { _ = reader.pausedThreadIDs } onChange: { refreshed.fulfill() }

        await reader.stopPausedDiscussion()
        await fulfillment(of: [refreshed], timeout: 2)

        XCTAssertEqual(wire.writes.map(\.0), ["groups.stop"])
        XCTAssertNil(reader.commandMessage)
        XCTAssertEqual(reader.feedback?.event, .stopped)
        XCTAssertEqual(reader.pauses[2]?.actionable, false)
        XCTAssertTrue(reader.pausedThreadIDs.isEmpty)
    }

    func testOtherWorkingThreadRequiresConfirmationBeforeStopping() async throws {
        let wire = RoomWire()
        let reader = try await openPausedRoom(wire)
        defer { reader.close() }
        wire.driverStatus = RoomFixture.status(running: 1, maxContinues: 5)

        await reader.poll()

        XCTAssertTrue(reader.mayStopPaused)
        XCTAssertTrue(reader.pausedStopNeedsConfirmation)
    }

    func testPollWithoutNewVisibleEventsDoesNotRepublishPauses() async throws {
        let wire = RoomWire()
        let reader = try await openPausedRoom(wire)
        defer { reader.close() }
        let initial = reader.pauses
        XCTAssertEqual(initial[2]?.actionable, true)
        let changed = expectation(description: "pauses were assigned again")
        withObservationTracking { _ = reader.pauses } onChange: { changed.fulfill() }

        await reader.poll()
        wire.latest = 3
        wire.roomEvents[3] = event(3, "room.activity", payload: ["status": .string("settled")])
        await reader.poll()

        XCTAssertEqual(reader.pauses, initial)
        XCTAssertEqual(reader.events.map(\.seq), [1, 2])
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0), .timedOut)
    }

    private func pauses(in events: [BotJSON], limit: Int = 5) -> [Int: BotRoomPause] {
        BotRoomPause.pauses(in: events.compactMap(BotRoomEvent.init), maxContinues: limit)
    }

    private func openPausedRoom(_ wire: RoomWire, advertisesContinue: Bool = true, limit: Int? = 5) async throws -> BotRoomReader {
        if advertisesContinue {
            var capabilities = try XCTUnwrap(RoomFixture.capabilities.fields)
            capabilities["methods"] = .array((RoomFixture.methods + ["groups.continue"]).map(BotJSON.string))
            wire.capabilities = .object(capabilities)
        }
        wire.latest = 2
        wire.roomEvents = [1: user(1), 2: bounded(2)]
        wire.driverStatus = RoomFixture.status(maxContinues: limit)
        let server = try XCTUnwrap(URL(string: "https://room-fixture.example"))
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: wire.latest)))
        let key = BotRoomKey(server: server, connectionID: connection.id, roomID: room.id)
        let reader = BotRoomReader(key: key, connection: connection, room: room, cache: BotHistoryCache(), makeWire: { _ in wire })
        await reader.open()
        return reader
    }

    private func user(_ seq: Int, thread: String = "thread") -> BotJSON {
        event(seq, "message.user", discussion: nil, thread: thread, eventID: "user:\(seq)", payload: ["text": .string("Start")])
    }

    private func bounded(_ seq: Int, discussion: String = "user:1", thread: String = "thread") -> BotJSON {
        event(seq, "room.activity", discussion: discussion, thread: thread,
              payload: ["status": .string("bounded"), "reason_code": .string("max_rounds")])
    }

    private func stop(_ seq: Int) -> BotJSON {
        event(seq, "room.stop_requested", discussion: nil, thread: nil)
    }

    private func event(_ seq: Int, _ kind: String, discussion: String? = "user:1", thread: String? = "thread",
                       eventID: String? = nil, payload: [String: BotJSON] = [:]) -> BotJSON {
        var fields = RoomFixture.event(seq, kind: kind).fields!
        var payload = payload
        fields["event_id"] = eventID.map(BotJSON.string)
        payload["discussion_event_id"] = discussion.map(BotJSON.string)
        payload["thread_id"] = thread.map(BotJSON.string)
        fields["payload"] = .object(payload)
        return .object(fields)
    }
}
