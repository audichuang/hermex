import XCTest
@testable import HermesMobile

@MainActor final class BotRoomContextTests: XCTestCase {
    func testStateContextSuppliesPurposeNotesAndRoutingWithoutReadingTheLogHeadAgain() async {
        let wire = RoomWire()
        wire.context = .object(["purpose": .string("Coordinate"), "notes": .string("Keep a record"),
                                "routing": .string("lead"), "lead_member_id": .string("chief")])
        wire.driverStatus = .object(["member_activity": .array([Self.activity]),
                                     "routing_modes": .array([.string("everyone"), .string("auto")])])
        let reader = makeReader(wire)
        await reader.open()
        XCTAssertTrue(reader.showsSettings)
        XCTAssertEqual(reader.context?.purpose, "Coordinate")
        XCTAssertEqual(reader.context?.notes, "Keep a record")
        XCTAssertEqual(reader.context?.routing, "lead")
        XCTAssertEqual(reader.context?.leadMemberID, "chief")
        XCTAssertEqual(reader.status.routingModes, ["everyone", "auto"])
        XCTAssertEqual(wire.logStarts, [0])

        wire.context = .object([:])
        await reader.poll()
        XCTAssertEqual(reader.context?.purpose, "")
        XCTAssertEqual(reader.context?.notes, "")
        XCTAssertEqual(reader.context?.routing, "everyone")
        XCTAssertNil(reader.context?.leadMemberID)
        reader.close()
        XCTAssertNil(reader.context)
    }

    func testUnknownRoutingRemainsReadableAndTextOnlySavesOmitRoutingFields() async throws {
        let wire = RoomWire()
        wire.context = .object(["routing": .string("future-mode"), "purpose": .string("Old purpose")])
        let reader = makeReader(wire)
        defer { reader.close() }
        await reader.open()
        let context = try XCTUnwrap(reader.context)
        XCTAssertEqual(context.routing, "future-mode")
        let draft = BotRoomSettingsDraft(context: context)
        draft.purpose = "New purpose"
        let saved = await draft.save(in: reader)
        XCTAssertTrue(saved)
        let params = try XCTUnwrap(wire.writes.last?.1)
        XCTAssertEqual(params["purpose"], .string("New purpose"))
        XCTAssertEqual(params["notes"], .string(""))
        XCTAssertNil(params["routing"])
        XCTAssertNil(params["lead_member_id"])
        XCTAssertEqual(reader.context?.routing, "future-mode")
    }

    func testSavingLeadAndEveryoneSendsRequiredFieldsAndUsesTheAcknowledgedContext() async throws {
        let wire = RoomWire()
        wire.context = .object([:])
        wire.latest = 2
        wire.roomEvents[1] = Self.event(1, kind: "room.context_set", payload: [
            "routing": .string("everyone"), "lead_member_id": .string("")
        ])
        wire.roomEvents[2] = Self.event(2, kind: "message.user", payload: [
            "thread_id": .string("discussion"), "text": .string("Please take a look")
        ])
        wire.driverStatus = .object(["member_activity": .array([Self.activity])])
        let reader = makeReader(wire)
        defer { reader.close() }
        await reader.open()
        let priorEvents = reader.roundEvents
        let draft = BotRoomSettingsDraft(context: try XCTUnwrap(reader.context))
        draft.purpose = "  A\nroom "
        draft.notes = " 筆記 "
        draft.routing = .lead("chief")
        let savedLead = await draft.save(in: reader)
        XCTAssertTrue(savedLead)
        let call = try XCTUnwrap(wire.writes.last)
        XCTAssertEqual(call.0, "groups.context")
        XCTAssertEqual(call.1["room_id"], .string("fixture-room"))
        XCTAssertEqual(call.1["purpose"], .string("  A\nroom "))
        XCTAssertEqual(call.1["notes"], .string(" 筆記 "))
        XCTAssertEqual(call.1["routing"], .string("lead"))
        XCTAssertEqual(call.1["lead_member_id"], .string("chief"))
        XCTAssertEqual(reader.context?.purpose, "A room")
        XCTAssertEqual(reader.context?.notes, "筆記")
        let round = BotRoomRound.build(events: priorEvents, activity: reader.status.activity, room: reader.room,
                                       threadID: "discussion", context: reader.context)
        XCTAssertEqual(round?.routingBy, "chief-of-staff")

        draft.routing = .everyone
        let savedEveryone = await draft.save(in: reader)
        XCTAssertTrue(savedEveryone)
        let everyone = try XCTUnwrap(wire.writes.last?.1)
        XCTAssertEqual(everyone["routing"], .string("everyone"))
        XCTAssertEqual(everyone["lead_member_id"], .string(""))
        XCTAssertNil(reader.context?.leadMemberID)
        let eventIDs = wire.writes.compactMap { $0.1["event_id"]?.text }.compactMap(UUID.init(uuidString:))
        XCTAssertEqual(Set(eventIDs).count, 2)
    }

    func testNotesCountTrimmedUTF8AndPreventOversizedSave() async throws {
        let wire = RoomWire()
        wire.context = .object([:])
        let reader = makeReader(wire)
        defer { reader.close() }
        await reader.open()
        let draft = BotRoomSettingsDraft(context: try XCTUnwrap(reader.context))
        XCTAssertEqual(BotRoomContext.notesBytes(" \n筆記\t "), 6)
        draft.notes = String(repeating: "字", count: 1365) + "a"
        XCTAssertEqual(draft.notesBytes, 4096)
        XCTAssertTrue(draft.maySave(in: reader))
        draft.notes += "字"
        XCTAssertFalse(draft.maySave(in: reader))
        let saved = await draft.save(in: reader)
        XCTAssertFalse(saved)
        XCTAssertTrue(wire.writes.isEmpty)
    }

    func testPurposeCountsScalarsAfterCollapsingWhitespaceAndPreventsOversizedSave() async throws {
        let wire = RoomWire()
        wire.context = .object([:])
        let reader = makeReader(wire)
        defer { reader.close() }
        await reader.open()
        let draft = BotRoomSettingsDraft(context: try XCTUnwrap(reader.context))
        XCTAssertEqual(BotRoomContext.purposeLength("👨‍👩‍👧‍👦"), 7)
        XCTAssertEqual(BotRoomContext.purposeLength("e\u{301}"), 2)
        XCTAssertEqual(BotRoomContext.purposeLength(" \u{1F}字\u{85}\n\t字  "), 3)
        draft.purpose = String(repeating: "👨‍👩‍👧‍👦", count: 71) + "abc"
        XCTAssertTrue(draft.maySave(in: reader))
        draft.purpose += "d"
        XCTAssertFalse(draft.maySave(in: reader))
        let saved = await draft.save(in: reader)
        XCTAssertFalse(saved)
        XCTAssertTrue(wire.writes.isEmpty)
    }

    func testAutoIsOfferedOnlyIfAdvertisedOrAlreadyInUse() async throws {
        let wire = RoomWire()
        wire.context = .object([:])
        let reader = makeReader(wire)
        defer { reader.close() }
        await reader.open()
        let draft = BotRoomSettingsDraft(context: try XCTUnwrap(reader.context))
        XCTAssertFalse(draft.offersAuto(in: reader))
        wire.driverStatus = .object(["routing_modes": .array([.string("auto")])])
        await reader.poll()
        XCTAssertTrue(draft.offersAuto(in: reader))
        wire.driverStatus = .object([:])
        wire.context = .object(["routing": .string("auto")])
        await reader.poll()
        XCTAssertTrue(draft.offersAuto(in: reader))
    }

    func testRejectionKeepsTheDraftAndShowsTheErrorInTheForm() async throws {
        let wire = RoomWire()
        wire.context = .object(["purpose": .string("Before")])
        wire.writeFailure = BotRoomFailure(code: 4128, reason: "invalid_params", message: "Settings rejected")
        let reader = makeReader(wire)
        defer { reader.close() }
        await reader.open()
        let draft = BotRoomSettingsDraft(context: try XCTUnwrap(reader.context))
        draft.purpose = "After"
        draft.notes = "New notes"
        draft.routing = .lead("chief")
        let held = expectation(description: "save started")
        var resume: CheckedContinuation<Void, Never>?
        wire.beforeWrite = { await withCheckedContinuation { resume = $0; held.fulfill() } }
        let save = Task { await draft.save(in: reader) }
        await fulfillment(of: [held], timeout: 2)
        XCTAssertTrue(draft.saving)
        XCTAssertFalse(draft.maySave(in: reader))
        resume?.resume()
        let saved = await save.value
        XCTAssertFalse(saved)
        XCTAssertFalse(draft.saving)
        XCTAssertEqual(draft.purpose, "After")
        XCTAssertEqual(draft.notes, "New notes")
        XCTAssertEqual(draft.routing, .lead("chief"))
        XCTAssertEqual(draft.error, "Settings rejected")
        XCTAssertEqual(reader.context?.purpose, "Before")
        XCTAssertTrue(draft.maySave(in: reader))
    }

    func testRoomSettingsRequireContextCapabilityAndLocalAuthority() async {
        let wire = RoomWire()
        let reader = makeReader(wire)
        defer { reader.close() }
        await reader.open()
        XCTAssertFalse(reader.showsSettings)
        wire.context = .object([:])
        var capabilities = RoomFixture.capabilities.fields!
        capabilities["methods"] = .array(RoomFixture.methods.map(BotJSON.string))
        wire.capabilities = .object(capabilities)
        await reader.open()
        XCTAssertFalse(reader.showsSettings)
        wire.capabilities = Self.settingsCapabilities
        wire.authority = "other-install"
        await reader.open()
        XCTAssertTrue(reader.foreignAuthority)
        XCTAssertFalse(reader.showsSettings)
    }

    func testPollStartedDuringSaveCannotOverwriteAcknowledgedContext() async throws {
        let wire = RoomWire()
        let oldContext = BotJSON.object(["purpose": .string("Before")])
        wire.context = oldContext
        let reader = makeReader(wire)
        defer { reader.close() }
        await reader.open()
        let draft = BotRoomSettingsDraft(context: try XCTUnwrap(reader.context))
        draft.purpose = "After"
        let writing = expectation(description: "write held")
        wire.holdWrite = true
        wire.onWriteHeld = { writing.fulfill() }
        let save = Task { await draft.save(in: reader) }
        await fulfillment(of: [writing], timeout: 2)
        let reading = expectation(description: "poll held")
        wire.holdState = true
        wire.onHeld = { reading.fulfill() }
        let poll = Task { await reader.poll() }
        await fulfillment(of: [reading], timeout: 2)

        wire.holdState = false
        wire.releaseWrite()
        let saved = await save.value
        XCTAssertTrue(saved)
        wire.releaseState(latest: 0, context: oldContext)
        await poll.value
        XCTAssertEqual(reader.context?.purpose, "After")
    }

    private static let activity = BotJSON.object(["member_id": .string("chief"),
                                                  "thread_id": .string("discussion"), "status": .string("running")])
    private static var settingsCapabilities: BotJSON {
        var fields = RoomFixture.capabilities.fields!
        fields["methods"] = .array((RoomFixture.methods + ["groups.context"]).map(BotJSON.string))
        return .object(fields)
    }

    private static func event(_ seq: Int, kind: String, payload: [String: BotJSON]) -> BotJSON {
        var fields = RoomFixture.event(seq, kind: kind).fields!
        fields["event_id"] = .string("event:\(seq)")
        fields["payload"] = .object(payload)
        return .object(fields)
    }

    private func makeReader(_ wire: RoomWire) -> BotRoomReader {
        wire.capabilities = Self.settingsCapabilities
        let server = URL(string: "https://fixture.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "", password: "")
        return BotRoomReader(key: .init(server: server, connectionID: connection.id, roomID: "fixture-room"),
                             connection: connection, room: BotGroupRoom(RoomFixture.room(latest: 0))!,
                             cache: BotHistoryCache(), makeWire: { _ in wire })
    }
}
