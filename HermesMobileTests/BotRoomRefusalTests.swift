import XCTest
@testable import HermesMobile

@MainActor final class BotRoomRefusalTests: XCTestCase {
    func testKnownRefusalsEachHaveAnExplanationThatOverridesTheServerMessage() throws {
        let reasons = [
            "session_busy", "unknown_execution", "stale_generation", "peer_unreachable",
            "unsupported_operation", "room_stop_pending", "room_disbanding_retry",
            "member_home_unknown", "peer_revoke_unsupported", "room approval is no longer pending",
            "runtime_coordination_required"
        ]
        var explanations = Set<String>()
        for reason in reasons {
            let failure = BotRoomFailure(code: 4001, reason: reason, message: "Server error")
            let explanation = try XCTUnwrap(failure.explanation, reason)
            XCTAssertFalse(explanation.isEmpty, reason)
            XCTAssertTrue(explanations.insert(explanation).inserted, reason)
            XCTAssertEqual(failure.localizedDescription, explanation, reason)
        }
        XCTAssertEqual(
            BotRoomFailure(code: 4001, reason: "runtime_coordination_required").localizedDescription,
            BotRoomFailure(code: 4123, reason: nil).localizedDescription
        )
    }

    func testUnknownAndExpiredRefusalsKeepTheirFallbacks() {
        let unknown = BotRoomFailure(code: 4001, reason: "future_reason")
        XCTAssertNil(unknown.explanation)
        XCTAssertEqual(unknown.localizedDescription, BotFailure.rejected(4001).localizedDescription)
        XCTAssertEqual(BotRoomFailure(code: 4001, reason: unknown.reason, message: "Server error").localizedDescription,
                       "Server error")

        let canonical = BotRoomFailure(code: 4001, reason: "room_history_expired")
        let standalone = BotRoomFailure(code: 4114, reason: nil)
        XCTAssertTrue(canonical.expired)
        XCTAssertTrue(standalone.expired)
        XCTAssertEqual(canonical.localizedDescription, String(localized: "This room’s history is no longer available."))
        XCTAssertEqual(standalone.localizedDescription, canonical.localizedDescription)
    }

    func testRoomKeepsReadingHistoryAndRestoresControlsAfterRuntimeRecovers() async throws {
        let wire = RoomWire()
        let reader = try makeReader(wire)
        await reader.open()
        defer { reader.close() }
        reader.draft = "Draft to keep"
        XCTAssertEqual(reader.primaryAction(in: nil), .send(enabled: true))
        XCTAssertTrue(reader.mayStop)
        XCTAssertTrue(reader.mayDownload)

        wire.includesDriverStatus = false
        wire.latest = 1
        wire.roomEvents[1] = RoomFixture.attachmentEvent(1, files: [RoomFixture.attachment("att_map")])
        await reader.poll()

        XCTAssertEqual(reader.link, .live)
        XCTAssertTrue(reader.runtimeDown)
        XCTAssertFalse(reader.maySend)
        XCTAssertEqual(reader.primaryAction(in: nil), .send(enabled: false))
        XCTAssertFalse(reader.mayEditDraft(in: nil))
        XCTAssertFalse(reader.mayStop)
        XCTAssertFalse(reader.mayDownload)
        XCTAssertEqual(reader.events.map(\.seq), [1])
        let file = try XCTUnwrap(reader.attachmentLists[1]?.files.first)
        XCTAssertEqual(file.name, "map.png")
        XCTAssertEqual(file.attachment.size, 100)
        let request = try XCTUnwrap(file.request)
        reader.previewAttachment(request, namespace: "fixture", observer: UUID()) { _ in
            XCTFail("An unavailable room should not start a preview")
        }
        do {
            _ = try await reader.downloadAttachment(request)
            XCTFail("An unavailable room should not download an attachment")
        } catch {
            XCTAssertEqual(error as? BotFailure, .stale)
        }
        XCTAssertTrue(wire.attachmentCalls.isEmpty)

        wire.includesDriverStatus = true
        await reader.poll()

        XCTAssertFalse(reader.runtimeDown)
        XCTAssertEqual(reader.draft, "Draft to keep")
        XCTAssertEqual(reader.primaryAction(in: nil), .send(enabled: true))
        XCTAssertTrue(reader.mayStop)
        XCTAssertTrue(reader.mayDownload)
    }

    func testRoomOpensWithDriverDisabledAndRecoversWithoutRefreshingCapabilities() async throws {
        let wire = RoomWire()
        let reader = try makeReader(wire, driver: false)
        wire.includesDriverStatus = false
        wire.latest = 1
        await reader.open()
        defer { reader.close() }

        reader.draft = "Draft"
        XCTAssertEqual(reader.link, .live)
        XCTAssertTrue(reader.runtimeDown)
        XCTAssertEqual(reader.events.map(\.seq), [1])
        XCTAssertFalse(reader.maySend)

        wire.includesDriverStatus = true
        await reader.poll()

        XCTAssertFalse(reader.runtimeDown)
        XCTAssertTrue(reader.maySend)

        wire.includesDriverStatus = false
        await reader.poll()
        XCTAssertTrue(reader.runtimeDown)
        reader.close()
        XCTAssertFalse(reader.runtimeDown)
    }

    func testRefusedRetryAndDiscardUnlockAndCanBeActedOnAgain() async throws {
        let wire = RoomWire()
        let reader = try makeReader(wire)
        wire.driverStatus = RoomFixture.status(actions: [
            pendingAction("retry", task: "task:1"),
            pendingAction("discard", task: "task:2")
        ])
        await reader.open()
        defer { reader.close() }
        let retry = reader.status.actions[0], discard = reader.status.actions[1]

        let busy = BotRoomFailure(code: 5118, reason: "session_busy")
        wire.writeFailure = busy
        await reader.act(retry)
        XCTAssertEqual(reader.commandMessage, busy.explanation)
        XCTAssertTrue(reader.mayAct(retry))
        wire.writeFailure = nil
        await reader.act(retry)
        XCTAssertEqual(wire.writes.map(\.0), ["groups.retry", "groups.retry"])

        let unreachable = BotRoomFailure(code: 4001, reason: "peer_unreachable")
        wire.writeFailure = unreachable
        await reader.act(discard)
        XCTAssertEqual(reader.commandMessage, unreachable.explanation)
        XCTAssertTrue(reader.mayAct(discard))
        wire.writeFailure = BotRoomFailure(code: 5124, reason: nil)
        await reader.act(discard)
        XCTAssertTrue(reader.mayAct(discard))
        wire.writeFailure = nil
        await reader.act(discard)
        XCTAssertEqual(wire.writes.filter { $0.0 == "groups.discard" }.count, 3)
    }

    func testActionWithUnknownOutcomeStaysLocked() async throws {
        let wire = RoomWire()
        let reader = try makeReader(wire)
        wire.driverStatus = RoomFixture.status(actions: [pendingAction("retry", task: "task:1")])
        await reader.open()
        defer { reader.close() }
        let retry = try XCTUnwrap(reader.status.actions.first)

        wire.writeFailure = BotFailure.transport
        await reader.act(retry)
        XCTAssertFalse(reader.mayAct(retry))

        wire.writeFailure = nil
        await reader.act(retry)
        XCTAssertEqual(wire.writes.count, 1)
    }

    private func pendingAction(_ kind: String, task: String, member: String = "chief") -> BotJSON {
        .object(["kind": .string(kind), "member_id": .string(member), "task_id": .string(task),
                 "execution_generation": .number(3)])
    }

    private func makeReader(_ wire: RoomWire, driver: Bool = true) throws -> BotRoomReader {
        var capabilities = try XCTUnwrap(RoomFixture.capabilities.fields)
        capabilities["driver"] = .bool(driver)
        capabilities["methods"] = .array((RoomFixture.methods + ["groups.discard", BotRoomAttachment.downloadMethod]).map(BotJSON.string))
        wire.capabilities = .object(capabilities)
        wire.driverStatus = RoomFixture.status(running: 1)
        let server = URL(string: "https://room-fixture.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 0)))
        let key = BotRoomKey(server: server, connectionID: connection.id, roomID: room.id)
        return BotRoomReader(key: key, connection: connection, room: room, cache: BotHistoryCache(), makeWire: { _ in wire })
    }
}
