import XCTest
@testable import HermesMobile

@MainActor final class BotRoomReasonTests: XCTestCase {
    private let knownCodes = [
        "member_unavailable",
        "runtime_offline",
        "queued_expired",
        "delivery_timeout",
        "agent_blocked",
        "cancelled",
        "provider_auth_or_access",
        "provider_quota_limit",
        "provider_rate_limit",
        "rate_limited",
        "provider_server_error",
        "context_overflow",
        "missing_config",
        "model_unavailable",
        "target_scope_unresolved",
        "superseded_by_newer_user_event",
        "turn_deadline_exceeded",
        "prepare_failed",
        "slot_wait_timeout",
        "target_busy",
        "member gateway restarted"
    ]

    func testEveryKnownCodeMapsToReadableText() throws {
        XCTAssertEqual(knownCodes.count, 21)
        for code in knownCodes {
            let text = try XCTUnwrap(BotRoomReason.text(code: code), "Missing mapped text for \(code)")
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertNotEqual(text, code, "Code \(code) should map to human-readable text")
        }
        XCTAssertEqual(BotRoomReason.text(code: "provider_rate_limit"), BotRoomReason.text(code: "rate_limited"))
    }

    func testTurnFailedPrefersKnownReasonCodeOverRawError() throws {
        let room = makeRoom()
        let event = try XCTUnwrap(BotRoomEvent(rawEvent(2, "turn.failed", payload: [
            "member_id": .string("ada"),
            "thread_id": .string("thread"),
            "reason_code": .string("provider_quota_limit"),
            "error": .string("HTTP 402 out of funds\nstack trace line")
        ])))
        let text = event.systemText(in: room)
        XCTAssertTrue(text.contains("Ada"))
        XCTAssertTrue(text.contains("The provider quota has been reached"))
        XCTAssertFalse(text.contains("HTTP 402"))
    }

    func testTurnFailedFallsBackToFirstLineOfFreeTextWhenReasonCodeIsUnknownOrMissing() throws {
        let room = makeRoom()
        let unknownCode = try XCTUnwrap(BotRoomEvent(rawEvent(2, "turn.failed", payload: [
            "member_id": .string("ada"),
            "thread_id": .string("thread"),
            "reason_code": .string("unknown"),
            "error": .string("Upstream gateway returned 503\nTraceback (most recent call last):")
        ])))
        let unknownText = unknownCode.systemText(in: room)
        XCTAssertTrue(unknownText.contains("Ada"))
        XCTAssertTrue(unknownText.contains("Upstream gateway returned 503"))
        XCTAssertFalse(unknownText.contains("Traceback"))

        let missingCode = try XCTUnwrap(BotRoomEvent(rawEvent(3, "turn.failed", payload: [
            "member_id": .string("linus"),
            "thread_id": .string("thread"),
            "error": .string("Socket closed unexpectedly\nmore details")
        ])))
        let missingText = missingCode.systemText(in: room)
        XCTAssertTrue(missingText.contains("Linus"))
        XCTAssertTrue(missingText.contains("Socket closed unexpectedly"))
        XCTAssertFalse(missingText.contains("more details"))
    }

    func testTurnFailedSuppressesUnknownCodeShapedReasonAndError() throws {
        let room = makeRoom()
        let event = try XCTUnwrap(BotRoomEvent(rawEvent(2, "turn.failed", payload: [
            "member_id": .string("ada"),
            "thread_id": .string("thread"),
            "reason_code": .string("unknown"),
            "error": .string("internal_error_code")
        ])))
        XCTAssertEqual(event.systemText(in: room), "Ada failed")
    }

    func testTurnCancelledShowsSupersededReasonAndSuppressesDefaultBoilerplate() throws {
        let room = makeRoom()
        let superseded = try XCTUnwrap(BotRoomEvent(rawEvent(2, "turn.cancelled", payload: [
            "member_id": .string("ada"),
            "thread_id": .string("thread"),
            "reason": .string("superseded_by_newer_user_event")
        ])))
        let supersededText = superseded.systemText(in: room)
        XCTAssertTrue(supersededText.contains("Ada"))
        XCTAssertTrue(supersededText.contains("A newer message replaced this turn"))

        let boilerplate = try XCTUnwrap(BotRoomEvent(rawEvent(3, "turn.cancelled", payload: [
            "member_id": .string("linus"),
            "thread_id": .string("thread"),
            "reason": .string("member turn cancelled")
        ])))
        XCTAssertEqual(boilerplate.systemText(in: room), "Linus cancelled")

        let freeText = try XCTUnwrap(BotRoomEvent(rawEvent(4, "turn.cancelled", payload: [
            "member_id": .string("ada"),
            "thread_id": .string("thread"),
            "reason": .string("Stopped by moderator\nextra context")
        ])))
        XCTAssertEqual(freeText.systemText(in: room), "Ada cancelled: Stopped by moderator")
    }

    func testTurnDeferredIsVisibleNamesMemberAndProducesUnavailableSeatAndHandoff() throws {
        let room = makeRoom()
        let user = try XCTUnwrap(BotRoomEvent(rawEvent(1, "message.user", eventID: "user:1", payload: [
            "text": .string("Please check"),
            "thread_id": .string("thread")
        ])))
        let memberMsg = try XCTUnwrap(BotRoomEvent(rawEvent(2, "message.member", actor: ["kind": .string("member"), "id": .string("ada")], payload: [
            "member_id": .string("ada"),
            "discussion_event_id": .string("user:1"),
            "thread_id": .string("thread"),
            "text": .string("Over to @linus")
        ])))
        let deferred = try XCTUnwrap(BotRoomEvent(rawEvent(3, "turn.deferred", payload: [
            "member_id": .string("linus"),
            "discussion_event_id": .string("user:1"),
            "thread_id": .string("thread"),
            "reason": .string("member_unavailable")
        ])))
        XCTAssertTrue(deferred.visible)
        XCTAssertFalse(deferred.isRoundSignal)
        XCTAssertEqual(deferred.systemText(in: room), "Linus didn’t answer in time")

        var log = BotRoomLog()
        log.apply(RoomFixture.page([
            rawEvent(1, "message.user", eventID: "user:1", payload: ["text": .string("Please check"), "thread_id": .string("thread")]),
            rawEvent(2, "message.member", actor: ["kind": .string("member"), "id": .string("ada")], payload: [
                "member_id": .string("ada"), "discussion_event_id": .string("user:1"),
                "thread_id": .string("thread"), "text": .string("Over to @linus")
            ]),
            rawEvent(3, "turn.deferred", payload: [
                "member_id": .string("linus"), "discussion_event_id": .string("user:1"),
                "thread_id": .string("thread"), "reason": .string("member_unavailable")
            ])
        ], cursor: 3))
        XCTAssertEqual(log.events.map(\.seq), [1, 2, 3])
        XCTAssertTrue(log.signals.isEmpty)

        let running = try XCTUnwrap(BotRoomMemberActivity(.object([
            "member_id": .string("ada"), "status": .string("running"),
            "thread_id": .string("thread"), "started_at": .number(1_000)
        ])))
        let round = try XCTUnwrap(BotRoomRound.build(events: [user, memberMsg, deferred], activity: [running], room: room, threadID: "thread"))
        XCTAssertEqual(round.seats.first { $0.memberID == "linus" }?.outcome, .unavailable)
        XCTAssertEqual(round.finished, 1)

        let handoffs = BotRoomHandoffs.find(in: log.events, members: room.members)
        XCTAssertEqual(handoffs[2], [BotRoomHandoff(afterSeq: 2, from: "ada", to: "linus")])

        let busyDeferred = try XCTUnwrap(BotRoomEvent(rawEvent(4, "turn.deferred", payload: [
            "member_id": .string("linus"),
            "discussion_event_id": .string("user:1"),
            "thread_id": .string("thread"),
            "reason": .string("target_busy")
        ])))
        XCTAssertEqual(busyDeferred.systemText(in: room), "Linus deferred: The bot is busy")
    }

    func testMemberUnavailableIsVisibleUnthreadedAndRoomLevel() throws {
        let room = makeRoom()
        let event = try XCTUnwrap(BotRoomEvent(rawEvent(5, "member.unavailable", actor: ["kind": .string("gateway"), "id": .string("fixture-install")], payload: [
            "reason_code": .string("prepare_failed"),
            "error": .string("Members could not be woken: launch timed out")
        ])))
        XCTAssertTrue(event.visible)
        XCTAssertFalse(event.isRoundSignal)
        XCTAssertNil(event.threadID)
        XCTAssertEqual(event.systemText(in: room), "Member unavailable: The bots could not be started")

        let freeText = try XCTUnwrap(BotRoomEvent(rawEvent(6, "member.unavailable", actor: ["kind": .string("gateway"), "id": .string("fixture-install")], payload: [
            "reason_code": .string("unknown"),
            "error": .string("Members could not be woken: launch timed out\nline 2")
        ])))
        XCTAssertEqual(freeText.systemText(in: room), "Member unavailable: Members could not be woken: launch timed out")
    }

    func testDepartedMembersOmitBlankNamesAcrossTurnNotices() throws {
        let room = makeRoom()
        let failed = try XCTUnwrap(BotRoomEvent(rawEvent(2, "turn.failed", payload: [
            "member_id": .string("departed"),
            "thread_id": .string("thread"),
            "reason_code": .string("model_unavailable"),
            "error": .string("model not found")
        ])))
        let failedNoReason = try XCTUnwrap(BotRoomEvent(rawEvent(3, "turn.failed", payload: [
            "member_id": .string("departed"),
            "thread_id": .string("thread"),
            "reason_code": .string("unknown"),
            "error": .string("unknown")
        ])))
        let cancelled = try XCTUnwrap(BotRoomEvent(rawEvent(4, "turn.cancelled", payload: [
            "member_id": .string("departed"),
            "thread_id": .string("thread"),
            "reason": .string("superseded_by_newer_user_event")
        ])))
        let cancelledPlain = try XCTUnwrap(BotRoomEvent(rawEvent(5, "turn.cancelled", payload: [
            "member_id": .string("departed"),
            "thread_id": .string("thread"),
            "reason": .string("member turn cancelled")
        ])))
        let deferred = try XCTUnwrap(BotRoomEvent(rawEvent(6, "turn.deferred", payload: [
            "member_id": .string("departed"),
            "thread_id": .string("thread"),
            "reason": .string("member_unavailable")
        ])))

        XCTAssertEqual(failed.systemText(in: room), "Failed: The selected model is unavailable")
        XCTAssertEqual(failedNoReason.systemText(in: room), "Turn failed")
        XCTAssertEqual(cancelled.systemText(in: room), "Turn cancelled: A newer message replaced this turn")
        XCTAssertEqual(cancelledPlain.systemText(in: room), "Turn cancelled")
        XCTAssertEqual(deferred.systemText(in: room), "The bot didn’t answer in time")
        for text in [failed, failedNoReason, cancelled, cancelledPlain, deferred].map({ $0.systemText(in: room) }) {
            XCTAssertFalse(text.hasPrefix(" "), "Departed member must not leave a leading blank space: \(text)")
        }
    }

    private func makeRoom() -> BotGroupRoom {
        BotGroupRoom(.object([
            "room_id": .string("fixture-room"),
            "name": .string("Comms"),
            "latest_seq": .number(0),
            "authority_gateway_id": .string("fixture-install"),
            "authority_epoch": .number(1),
            "members": .array([
                .object(["member_id": .string("ada"), "display_name": .string("Ada"), "handle": .string("ada")]),
                .object(["member_id": .string("linus"), "display_name": .string("Linus"), "handle": .string("linus")])
            ])
        ]))!
    }

    private func rawEvent(_ seq: Int, _ kind: String, eventID: String? = nil,
                          actor: [String: BotJSON] = ["kind": .string("gateway"), "id": .string("fixture-install")],
                          payload: [String: BotJSON]) -> BotJSON {
        var fields: [String: BotJSON] = [
            "room_id": .string("fixture-room"),
            "seq": .number(Double(seq)),
            "kind": .string(kind),
            "actor": .object(actor),
            "payload": .object(payload)
        ]
        if let eventID { fields["event_id"] = .string(eventID) }
        return .object(fields)
    }
}
