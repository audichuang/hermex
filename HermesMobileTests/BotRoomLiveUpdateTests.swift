import Observation
import XCTest
@testable import HermesMobile

@MainActor final class BotRoomLiveUpdateTests: XCTestCase {
    func testRoomPushReadsStateAndShowsTheNewMessage() async {
        let wire = RoomWire()
        wire.changeEvents = true
        let reader = makeReader(wire)
        await reader.open()
        defer { reader.close() }

        let changed = observeChange("Room transcript updated") { _ = reader.events }
        wire.latest = 1
        wire.onEvent?(roomChange())
        await fulfillment(of: [changed], timeout: 3)

        XCTAssertEqual(reader.events.map(\.seq), [1])
        XCTAssertEqual(wire.stateCalls, 2)
        XCTAssertEqual(wire.logStarts, [0, 0])
        XCTAssertEqual(reader.pollInterval, .seconds(15))
    }

    func testAnotherRoomsPushIsIgnoredAndABroadcastWithoutRoomIDsRefreshes() async {
        let wire = RoomWire()
        wire.changeEvents = true
        let reader = makeReader(wire)
        await reader.open()
        defer { reader.close() }

        wire.latest = 1
        wire.onEvent?(roomChange(roomIDs: ["another-room"]))
        await reader.poll()
        XCTAssertEqual(wire.stateCalls, 2)

        for roomIDs in [nil, []] as [[String]?] {
            let changed = observeChange("Unscoped broadcast updated the room") { _ = reader.events }
            wire.latest += 1
            wire.onEvent?(roomChange(roomIDs: roomIDs, id: nil))
            await fulfillment(of: [changed], timeout: 3)
        }
        XCTAssertEqual(reader.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(wire.stateCalls, 4)
    }

    func testDuplicateBroadcastDoesNotRefreshEvenAfterAnotherBroadcast() async {
        let wire = RoomWire()
        wire.changeEvents = true
        let reader = makeReader(wire)
        await reader.open()
        defer { reader.close() }

        for (index, id) in ["epoch:1", "epoch:2"].enumerated() {
            let changed = observeChange("Broadcast \(id) updated the room") { _ = reader.events }
            wire.latest = index + 1
            wire.onEvent?(roomChange(id: id))
            await fulfillment(of: [changed], timeout: 3)
        }
        wire.onEvent?(roomChange(id: "epoch:1"))
        await reader.poll()
        XCTAssertEqual(wire.stateCalls, 4)
        XCTAssertEqual(wire.logStarts, [0, 0, 1])
    }

    func testFalseOrMissingCapabilityKeepsPollingAndIgnoresPush() async {
        for capability in [false, nil] as [Bool?] {
            let wire = RoomWire()
            wire.changeEvents = capability
            let reader = makeReader(wire)
            await reader.open()
            defer { reader.close() }

            XCTAssertEqual(reader.pollInterval, .seconds(10))
            wire.driverStatus = RoomFixture.status(running: 1)
            wire.onEvent?(roomChange())
            await reader.poll()
            XCTAssertEqual(reader.pollInterval, .seconds(2))
            XCTAssertEqual(wire.stateCalls, 2)
        }
    }

    func testPushWhileReadingQueuesOneFollowUpAndKeepsWorkingBackstop() async {
        let wire = RoomWire()
        wire.changeEvents = true
        let reader = makeReader(wire)
        await reader.open()
        defer { reader.close() }

        let held = expectation(description: "First poll awaiting state")
        wire.holdState = true
        wire.onHeld = { [weak wire] in
            wire?.holdState = false
            held.fulfill()
        }
        let poll = Task { await reader.poll() }
        await fulfillment(of: [held], timeout: 3)
        wire.latest = 1
        let changed = observeChange("Queued poll updated the room") { _ = reader.events }
        wire.onEvent?(roomChange(id: "epoch:1"))
        wire.onEvent?(roomChange(roomIDs: [], id: "epoch:2"))
        XCTAssertEqual(wire.stateCalls, 2)
        wire.releaseState(latest: 0)
        await poll.value
        await fulfillment(of: [changed], timeout: 3)

        XCTAssertEqual(reader.events.map(\.seq), [1])
        wire.driverStatus = RoomFixture.status(running: 1)
        await reader.poll()
        XCTAssertEqual(reader.pollInterval, .seconds(2))
        XCTAssertEqual(wire.stateCalls, 4)
        XCTAssertEqual(wire.logStarts, [0, 0])
    }

    func testReconnectReadsStateAndLogAndOnlyTheNewWireCanRefresh() async throws {
        let wire = RoomWire(), next = RoomWire()
        wire.changeEvents = true; next.changeEvents = true
        let reader = makeReader(wire, then: next)
        await reader.open(owner: UUID())
        defer { reader.close() }
        let lateEvent = try XCTUnwrap(wire.onEvent)

        let held = expectation(description: "Reconnect requested state")
        next.holdState = true
        next.onHeld = { held.fulfill() }
        next.latest = 1
        wire.onDisconnect?(BotFailure.transport)
        XCTAssertNil(wire.onEvent)
        await fulfillment(of: [held], timeout: 3)

        let live = observeChange("Reconnect opened the room") { _ = reader.link }
        next.holdState = false
        next.releaseState(latest: 1)
        await fulfillment(of: [live], timeout: 3)
        XCTAssertEqual(reader.link, .live)
        XCTAssertEqual(reader.events.map(\.seq), [1])
        XCTAssertEqual(next.stateCalls, 1)
        XCTAssertEqual(next.logStarts, [0])

        lateEvent(roomChange())
        await reader.poll()
        XCTAssertEqual(next.stateCalls, 2)

        let changed = observeChange("New wire updated the room") { _ = reader.events }
        next.latest = 2
        next.onEvent?(roomChange())
        await fulfillment(of: [changed], timeout: 3)
        XCTAssertEqual(reader.events.map(\.seq), [1, 2])
        XCTAssertEqual(wire.stateCalls, 1)
        XCTAssertEqual(next.stateCalls, 3)
        XCTAssertEqual(next.logStarts, [0, 1])
    }

    private func makeReader(_ wire: RoomWire, then next: RoomWire? = nil) -> BotRoomReader {
        let address = URL(string: "https://rooms.example")!
        let connection = BotConnection(id: UUID(), name: "Room test", address: address, username: "u", password: "p")
        let room = BotGroupRoom(RoomFixture.room(latest: 0))!
        let key = BotRoomKey(server: address, connectionID: connection.id, roomID: room.id)
        var wires = [wire] + [next].compactMap { $0 }
        return BotRoomReader(key: key, connection: connection, room: room, cache: BotHistoryCache(),
                             makeWire: { _ in wires.removeFirst() }, reconnectDelays: [.zero], isNetworkAvailable: { true })
    }

    private func roomChange(roomIDs: [String]? = ["fixture-room"], id: String? = "epoch:1") -> BotJSON {
        var payload: [String: BotJSON] = [:]
        payload["room_ids"] = roomIDs.map { .array($0.map(BotJSON.string)) }
        payload["broadcast_id"] = id.map(BotJSON.string)
        return .object(["type": .string("groups.changed"), "session_id": .string(""), "payload": .object(payload)])
    }

    private func observeChange(_ description: String, _ read: () -> Void) -> XCTestExpectation {
        let observed = expectation(description: description)
        withObservationTracking(read, onChange: { observed.fulfill() })
        return observed
    }
}
