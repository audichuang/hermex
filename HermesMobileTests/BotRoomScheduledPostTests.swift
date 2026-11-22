import XCTest
@testable import HermesMobile

@MainActor final class BotRoomScheduledPostTests: XCTestCase {
    private let server = URL(string: "https://one.example")!
    private let connectionID = UUID()

    private var room: BotGroupRoom {
        BotGroupRoom(RoomFixture.room(latest: 2))!
    }

    private func scheduledEvent(
        seq: Int = 1,
        actorID: String = "cron:daily-brief",
        displayName: String? = "Morning Brief",
        includeActorKind: Bool = true,
        text: String = "Daily summary ready",
        threadID: String? = "cron-abc123"
    ) -> BotJSON {
        var actor: [String: BotJSON] = ["id": .string(actorID)]
        if includeActorKind { actor["kind"] = .string("user") }
        if let displayName { actor["display_name"] = .string(displayName) }
        var payload: [String: BotJSON] = ["text": .string(text)]
        if let threadID { payload["thread_id"] = .string(threadID) }
        return .object([
            "room_id": .string("fixture-room"),
            "seq": .number(Double(seq)),
            "event_id": .string("cron-post:digest\(seq)"),
            "kind": .string("message.user"),
            "actor": .object(actor),
            "payload": .object(payload),
            "created_at": .number(1_700_000_000)
        ])
    }

    func testScheduledPostDetectionCoversCronAndNoticePrefixesIncludingDiskReplay() throws {
        let post = try XCTUnwrap(BotRoomEvent(scheduledEvent(actorID: "cron:morning-brief")))
        let notice = try XCTUnwrap(BotRoomEvent(scheduledEvent(actorID: "cron-notice:morning-brief")))
        let diskRestored = try XCTUnwrap(BotRoomEvent(scheduledEvent(actorID: "cron:morning-brief", includeActorKind: false)))
        let diskRestoredNotice = try XCTUnwrap(BotRoomEvent(scheduledEvent(actorID: "cron-notice:morning-brief", includeActorKind: false)))

        XCTAssertTrue(post.isScheduledPost)
        XCTAssertTrue(notice.isScheduledPost)
        XCTAssertTrue(diskRestored.isScheduledPost)
        XCTAssertTrue(diskRestoredNotice.isScheduledPost)

        let ownDesktop = try XCTUnwrap(BotRoomEvent(.object([
            "seq": .number(2),
            "kind": .string("message.user"),
            "actor": .object(["kind": .string("user"), "id": .string("desktop")]),
            "payload": .object(["text": .string("Hello"), "thread_id": .string("t1")])
        ])))
        let memberWithCronID = try XCTUnwrap(BotRoomEvent(.object([
            "seq": .number(3),
            "kind": .string("message.member"),
            "actor": .object(["kind": .string("member"), "id": .string("cron:not-user"), "display_name": .string("Chief")]),
            "payload": .object(["text": .string("Hi"), "thread_id": .string("t1")])
        ])))

        XCTAssertFalse(ownDesktop.isScheduledPost)
        XCTAssertFalse(memberWithCronID.isScheduledPost)
    }

    func testAuthorNameUsesJobNameForScheduledPostsAndKeepsYouForOwnMessages() throws {
        let post = try XCTUnwrap(BotRoomEvent(scheduledEvent(actorID: "cron:daily", displayName: "Morning Brief")))
        XCTAssertEqual(post.authorName(in: room), "Morning Brief")

        let fallbackFromCron = try XCTUnwrap(BotRoomEvent(scheduledEvent(actorID: "cron:daily-job", displayName: "  ")))
        XCTAssertEqual(fallbackFromCron.authorName(in: room), "daily-job")

        let fallbackFromNotice = try XCTUnwrap(BotRoomEvent(scheduledEvent(actorID: "cron-notice:nightly-job", displayName: nil)))
        XCTAssertEqual(fallbackFromNotice.authorName(in: room), "nightly-job")

        let emptyID = try XCTUnwrap(BotRoomEvent(scheduledEvent(actorID: "cron:", displayName: nil)))
        XCTAssertEqual(emptyID.authorName(in: room), String(localized: "Scheduled"))

        let own = try XCTUnwrap(BotRoomEvent(.object([
            "seq": .number(2),
            "kind": .string("message.user"),
            "actor": .object(["kind": .string("user"), "id": .string("desktop")]),
            "payload": .object(["text": .string("Hello")])
        ])))
        XCTAssertEqual(own.authorName(in: room), String(localized: "You"))

        let member = try XCTUnwrap(BotRoomEvent(RoomFixture.event(3, kind: "message.member")))
        XCTAssertEqual(member.authorName(in: room), "chief-of-staff")
    }

    func testThreadPreviewAuthorUsesJobNameForScheduledPostRoot() throws {
        let wire = RoomWire()
        let connection = BotConnection(id: connectionID, name: "Mac", address: server, username: "u", password: "p", hermesVersion: nil)
        let reader = BotRoomReader(
            key: BotRoomKey(server: server, connectionID: connectionID, roomID: room.id),
            connection: connection,
            room: room,
            cache: BotHistoryCache(),
            makeWire: { _ in wire }
        )

        let scheduledRoot = try XCTUnwrap(BotRoomEvent(scheduledEvent(seq: 1, displayName: "Morning Brief", threadID: "cron-thread")))
        let scheduledThread = BotRoomThread(id: "cron-thread", events: [scheduledRoot], historyIsPartial: false)
        let scheduledPreview = BotRoomThreadPreview(thread: scheduledThread, reader: reader, rootFiles: nil)
        XCTAssertEqual(scheduledPreview.authorTitle, "Morning Brief")

        let ownRoot = try XCTUnwrap(BotRoomEvent(.object([
            "seq": .number(2),
            "kind": .string("message.user"),
            "actor": .object(["kind": .string("user"), "id": .string("desktop")]),
            "payload": .object(["text": .string("Manual post"), "thread_id": .string("user-thread")])
        ])))
        let ownThread = BotRoomThread(id: "user-thread", events: [ownRoot], historyIsPartial: false)
        let ownPreview = BotRoomThreadPreview(thread: ownThread, reader: reader, rootFiles: nil)
        XCTAssertEqual(ownPreview.authorTitle, String(localized: "You"))

        let partialThread = BotRoomThread(id: "cron-thread", events: [scheduledRoot], historyIsPartial: true)
        let partialPreview = BotRoomThreadPreview(thread: partialThread, reader: reader, rootFiles: nil)
        XCTAssertEqual(partialPreview.authorTitle, String(localized: "Thread"))
    }

    func testHistoryCacheStoresJobNameAsSenderAndPreservesScheduledPostAcrossDiskReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BotHistoryCache(directory: directory)
        let key = BotRoomKey(server: server, connectionID: connectionID, roomID: room.id)
        let scope = BotHistoryCache.Scope(server: server, connectionID: connectionID)

        let scheduled = scheduledEvent(seq: 1, actorID: "cron:morning-brief", displayName: "Morning Brief",
                                       text: "Status green for morning digest", threadID: "cron-thread")
        let own: BotJSON = .object([
            "room_id": .string(room.id),
            "seq": .number(2),
            "event_id": .string("user:2"),
            "kind": .string("message.user"),
            "actor": .object(["kind": .string("user"), "id": .string("desktop")]),
            "payload": .object(["text": .string("Manual morning note"), "thread_id": .string("user-thread")])
        ])
        try await cache.appendRoom(key: key, room: room, page: RoomFixture.page([scheduled, own], cursor: 2), since: 0)

        let reopened = BotHistoryCache(directory: directory)
        let hits = try await reopened.search("morning", scope: scope, roomIDs: [room.id])
        XCTAssertEqual(hits.map(\.message.seq), [2, 1])
        XCTAssertEqual(hits.first(where: { $0.message.seq == 1 })?.message.sender, "Morning Brief")
        XCTAssertEqual(hits.first(where: { $0.message.seq == 2 })?.message.sender, String(localized: "You"))

        let snapshot = try await reopened.roomHistory(key)
        let events = try XCTUnwrap(snapshot?.replayPage["events"].list).compactMap(BotRoomEvent.init)
        let restoredScheduled = try XCTUnwrap(events.first { $0.seq == 1 })
        let restoredOwn = try XCTUnwrap(events.first { $0.seq == 2 })
        XCTAssertTrue(restoredScheduled.isScheduledPost)
        XCTAssertEqual(restoredScheduled.authorName(in: room), "Morning Brief")
        XCTAssertFalse(restoredOwn.isScheduledPost)
        XCTAssertEqual(restoredOwn.authorName(in: room), String(localized: "You"))
    }

    func testDeliveryTargetAppendsProfileIncludingDefaultAndOmitsWhenMissing() {
        XCTAssertEqual(BotRoomDeliveryTarget.address(roomID: "room-1", profile: "default"), "room:room-1@default")
        XCTAssertEqual(BotRoomDeliveryTarget.address(roomID: "room-1", profile: "work"), "room:room-1@work")
        XCTAssertEqual(BotRoomDeliveryTarget.address(roomID: "room-1", profile: "  ops  "), "room:room-1@ops")
        XCTAssertEqual(BotRoomDeliveryTarget.address(roomID: "room-1", profile: nil), "room:room-1")
        XCTAssertEqual(BotRoomDeliveryTarget.address(roomID: "room-1", profile: "   "), "room:room-1")
    }
}
