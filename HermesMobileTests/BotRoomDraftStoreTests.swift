import CryptoKit
import XCTest
@testable import HermesMobile

@MainActor final class BotRoomDraftStoreTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let connection = BotConnection(id: UUID(), name: "Fixture", address: URL(string: "https://rooms.example")!,
                                           username: "fixture", password: "fixture")
    private let room = BotGroupRoom(RoomFixture.room(latest: 0))!
    private var key: BotRoomKey { .init(server: connection.address, connectionID: connection.id, roomID: room.id) }
    private var disk: BotRoomDraftStore { .init(directory: directory) }

    nonisolated override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testDraftTextRoundTripsWithoutReplyTargetsOrUnsentAttachments() async throws {
        let wire = attachmentWire()
        wire.members = [.object(["member_id": .string("chief"), "handle": .string("chief")])]
        let reader = makeReader(wire)
        await reader.open()
        defer { reader.close() }
        reader.draft = "  Overview draft\n"
        reader.setDraft("Reply draft", in: "discussion")
        var reply = RoomFixture.event(2, kind: "message.member").fields!
        reply["payload"] = .object(["text": .string("Update"), "member_id": .string("chief")])
        reader.beginReply(to: try XCTUnwrap(BotRoomEvent(.object(reply))), in: "discussion")
        XCTAssertNotNil(reader.replyTarget(in: "discussion"))
        reader.setDraft("Discard this", in: "other")
        reader.setDraft("", in: "other")
        await attachFile(to: reader)
        XCTAssertFalse(reader.attachmentChips(in: nil).isEmpty)
        reader.close()

        let restored = makeReader(RoomWire())
        XCTAssertEqual(restored.draft, "  Overview draft\n")
        XCTAssertEqual(restored.draft(in: "discussion"), "@chief Reply draft")
        XCTAssertNil(restored.replyTarget(in: "discussion"))
        XCTAssertTrue(restored.draft(in: "other").isEmpty)
        XCTAssertTrue(restored.attachmentChips(in: nil).isEmpty)
        XCTAssertNil(restored.uncertainSend)
    }

    func testRestoredThreadRetryReusesIdentityAndAcknowledgmentClearsTheSavedSend() async throws {
        let wire = RoomWire(), reader = makeReader(wire)
        wire.latest = 1
        wire.roomEvents[1] = RoomFixture.attachmentEvent(1, text: "Thread root", threadID: "discussion", files: [])
        await reader.open()
        reader.draft = "Overview draft"
        reader.setDraft("Reply draft", in: "discussion")
        wire.writeFailure = BotFailure.transport
        await reader.send(threadID: "discussion")
        let original = try XCTUnwrap(reader.uncertainSend(in: "discussion"))
        reader.close()

        wire.writeFailure = nil
        let restored = makeReader(wire)
        await restored.open()
        defer { restored.close() }
        XCTAssertEqual(restored.uncertainSend(in: "discussion"), original)
        XCTAssertTrue(restored.mayResend(in: "discussion"))
        XCTAssertEqual(wire.writes.count, 1)
        await restored.send(retry: true, threadID: "discussion")

        let retry = try XCTUnwrap(wire.writes.last?.1)
        XCTAssertEqual(retry["event_id"]?.text, original.eventID)
        XCTAssertEqual(retry["payload"]?["thread_id"].text, original.threadID)
        XCTAssertNil(restored.uncertainSend(in: "discussion"))
        XCTAssertEqual(disk.load(key).draft.texts, ["": "Overview draft"])
        XCTAssertTrue(disk.load(key).draft.pending.isEmpty)
    }

    func testFirstLogReadSettlesTheRestoredSendWithoutRetry() async throws {
        let wire = RoomWire(), reader = makeReader(wire)
        await reader.open()
        reader.draft = "Already delivered"
        reader.setDraft("Keep this draft", in: "another-thread")
        wire.loseWrite = true
        await reader.send()
        let original = try XCTUnwrap(reader.uncertainSend)
        reader.close()

        wire.loseWrite = false
        let restored = makeReader(wire)
        XCTAssertEqual(restored.uncertainSend, original)
        await restored.open()
        defer { restored.close() }

        XCTAssertFalse(restored.mayResend(in: nil))
        XCTAssertNil(restored.uncertainSend)
        XCTAssertEqual(restored.primaryAction(in: nil), .send(enabled: false))
        XCTAssertNil(restored.commandMessage)
        XCTAssertEqual(restored.events.map(\.eventID), [original.serverEventID])
        XCTAssertEqual(wire.writes.count, 1)
        XCTAssertTrue(disk.load(key).draft.pending.isEmpty)
        XCTAssertEqual(disk.load(key).draft.texts, ["another-thread": "Keep this draft"])
    }

    func testOverviewAndDiscussionRestoreTheirUncertainSendsAndRetryTheOriginal() async throws {
        let store = disk
        let wire = RoomWire(), reader = makeReader(wire, store: store)
        wire.latest = 1
        wire.roomEvents[1] = RoomFixture.attachmentEvent(1, text: "Thread root", threadID: "discussion", files: [])
        await reader.open()
        defer { reader.close() }
        reader.draft = "First send"
        reader.setDraft("Second send", in: "discussion")
        wire.writeFailure = BotFailure.transport
        await reader.send()
        let first = try XCTUnwrap(reader.uncertainSend)
        await reader.send(threadID: "discussion")
        let second = try XCTUnwrap(reader.uncertainSend(in: "discussion"))
        reader.close()

        wire.writeFailure = nil
        let restored = makeReader(wire, store: store)
        await restored.open()
        defer { restored.close() }
        XCTAssertEqual(restored.uncertainSend?.eventID, first.eventID)
        XCTAssertEqual(restored.uncertainSend(in: "discussion")?.eventID, second.eventID)
        XCTAssertEqual(restored.primaryAction(in: nil), .retry(enabled: true))
        XCTAssertEqual(restored.primaryAction(in: "discussion"), .retry(enabled: true))
        await restored.send(retry: true, threadID: "discussion")

        XCTAssertEqual(wire.writes.count, 3)
        let retry = try XCTUnwrap(wire.writes.last?.1)
        XCTAssertEqual(retry["event_id"]?.text, second.eventID)
        XCTAssertEqual(retry["payload"]?["thread_id"].text, second.threadID)
        XCTAssertNil(restored.uncertainSend(in: "discussion"))
        XCTAssertEqual(restored.uncertainSend?.eventID, first.eventID)
        XCTAssertEqual(store.load(key).draft.texts, ["": "First send"])
    }

    func testLegacyDraftRestoresItsSinglePendingSendAndAllTexts() async throws {
        func digest(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let folder = directory.appendingPathComponent(digest(key.server.absoluteString))
            .appendingPathComponent(key.connectionID.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = """
        {
          "texts": {"": "Overview draft", "discussion": "Reply draft"},
          "pending": {
            "text": "Reply draft", "eventID": "original-event", "attachments": [],
            "threadID": "discussion", "contextThreadID": "discussion"
          }
        }
        """
        try Data(legacy.utf8).write(to: folder.appendingPathComponent(digest(key.roomID) + ".json"))

        let draft = disk.load(key).draft
        XCTAssertEqual(draft.texts, ["": "Overview draft", "discussion": "Reply draft"])
        XCTAssertEqual(draft.pending.count, 1)
        let restored = try XCTUnwrap(draft.pending.first)
        XCTAssertEqual(restored.eventID, "original-event")
        XCTAssertEqual(restored.threadID, "discussion")
        XCTAssertEqual(restored.contextThreadID, "discussion")
        XCTAssertEqual(restored.text, "Reply draft")
    }

    func testForwardedSendWithoutAnOwnerReplyRestoresAndRetriesTheOriginal() async throws {
        let store = disk
        let wire = RoomWire(), reader = makeReader(wire, store: store)
        await reader.open()
        defer { reader.close() }
        reader.draft = "Message sent through a forwarder"
        wire.writeFailure = BotRoomFailure(code: 5124, reason: nil)
        await reader.send()
        let eventID = try XCTUnwrap(wire.writes.last?.1["event_id"]?.text)
        XCTAssertEqual(reader.uncertainSend?.eventID, eventID)
        reader.close()

        let restored = makeReader(wire, store: store)
        XCTAssertEqual(restored.uncertainSend?.eventID, eventID)
        wire.writeFailure = nil
        await restored.open()
        defer { restored.close() }
        XCTAssertEqual(restored.primaryAction(in: nil), .retry(enabled: true))
        await restored.send(retry: true)

        XCTAssertEqual(wire.writes.count, 2)
        XCTAssertEqual(wire.writes.last?.1["event_id"]?.text, eventID)
    }

    func testSendIsRecoverableBeforeTheReplyOrSuspendRuns() async throws {
        let store = disk
        let wire = RoomWire(), reader = makeReader(wire, store: store, draftSaveDelay: .seconds(3600))
        wire.latest = 1
        wire.roomEvents[1] = RoomFixture.attachmentEvent(1, text: "Thread root", threadID: "discussion", files: [])
        await reader.open()
        defer { reader.close() }
        reader.draft = "Earlier send"
        wire.writeFailure = BotFailure.transport
        await reader.send()
        let earlier = try XCTUnwrap(reader.uncertainSend)

        reader.setDraft("In flight", in: "discussion")
        wire.writeFailure = nil
        wire.holdWrite = true
        let held = expectation(description: "Send dispatched without a reply")
        wire.onWriteHeld = { held.fulfill() }
        let send = Task { await reader.send(threadID: "discussion") }
        await fulfillment(of: [held], timeout: 2)

        let restored = makeReader(RoomWire(), store: store)
        let eventID = wire.writes.last?.1["event_id"]?.text
        wire.releaseWrite()
        await send.value
        XCTAssertNotNil(eventID)
        XCTAssertEqual(restored.uncertainSend, earlier)
        XCTAssertEqual(restored.uncertainSend(in: "discussion")?.eventID, eventID)
        XCTAssertEqual(restored.draft(in: "discussion"), "In flight")
        XCTAssertEqual(store.load(key).draft.pending, [earlier])
    }

    func testExplicitRejectionDoesNotRestoreAnUncertainSend() async {
        let wire = RoomWire(), reader = makeReader(wire)
        await reader.open()
        defer { reader.close() }
        reader.draft = "Keep rejected text"
        wire.writeFailure = BotRoomFailure(code: 4001, reason: "invalid_params")
        await reader.send()

        let restored = makeReader(RoomWire())
        XCTAssertNil(restored.uncertainSend)
        XCTAssertEqual(restored.draft, "Keep rejected text")
    }

    func testRejectedRestoredTextRetryUnlocksTheDraftAcrossRelaunches() async throws {
        let refusals = [BotRoomFailure(code: 4001, reason: "invalid_params"),
                        BotRoomFailure(code: 5112, reason: nil, admitted: false)]
        for refusal in refusals {
            let store = BotRoomDraftStore(directory: directory.appendingPathComponent(String(refusal.code)))
            let wire = RoomWire(), reader = makeReader(wire, store: store)
            await reader.open()
            reader.draft = "Edit and send again"
            wire.writeFailure = BotFailure.transport
            await reader.send()
            let original = try XCTUnwrap(reader.uncertainSend)
            reader.close()

            let restored = makeReader(wire, store: store)
            await restored.open()
            defer { restored.close() }
            XCTAssertEqual(restored.primaryAction(in: nil), .retry(enabled: true))
            wire.writeFailure = refusal
            await restored.send(retry: true)

            XCTAssertEqual(wire.writes.last?.1["event_id"]?.text, original.eventID)
            XCTAssertTrue(restored.mayEditDraft(in: nil), "Refusal \(refusal.code) must unlock the composer")
            XCTAssertEqual(restored.primaryAction(in: nil), .send(enabled: true))
            XCTAssertEqual(restored.commandMessage, refusal.localizedDescription)

            let reopened = makeReader(RoomWire(), store: store)
            XCTAssertNil(reopened.uncertainSend)
            XCTAssertEqual(reopened.draft, original.text)
            XCTAssertTrue(reopened.mayEditDraft(in: nil))
        }
    }

    func testRejectedRestoredTextRetryConfirmsTheMessageIfItLanded() async throws {
        let wire = RoomWire(), reader = makeReader(wire)
        await reader.open()
        reader.draft = "Already delivered"
        reader.setDraft("Keep this reply", in: "another-thread")
        wire.loseWrite = true
        await reader.send()
        let original = try XCTUnwrap(reader.uncertainSend)
        reader.close()

        wire.latest = 0
        wire.loseWrite = false
        let restored = makeReader(wire)
        await restored.open()
        defer { restored.close() }
        XCTAssertTrue(restored.mayResend(in: nil))
        wire.latest = 1
        wire.writeFailure = BotRoomFailure(code: 4001, reason: "invalid_params")
        await restored.send(retry: true)

        XCTAssertEqual(restored.events.map(\.eventID), [original.serverEventID])
        XCTAssertEqual(restored.primaryAction(in: nil), .send(enabled: false))
        XCTAssertNil(restored.commandMessage)

        let reopened = makeReader(RoomWire())
        XCTAssertNil(reopened.uncertainSend)
        XCTAssertTrue(reopened.draft.isEmpty)
        XCTAssertEqual(reopened.draft(in: "another-thread"), "Keep this reply")
    }

    func testExpiredRestoredAttachmentRetryRestoresTextWhenTheEventNeverLanded() async throws {
        let (wire, restored, original) = try await restoreAttachmentSend(delivered: false)
        defer { restored.close() }
        wire.writeFailure = BotRoomFailure(code: 4001, reason: "invalid_params")
        await restored.send(retry: true)

        XCTAssertEqual(wire.writes.last?.1["event_id"]?.text, original.eventID)
        XCTAssertNil(restored.uncertainSend)
        XCTAssertEqual(restored.draft, original.text)
        XCTAssertTrue(restored.attachmentChips(in: nil).isEmpty)
        XCTAssertTrue(restored.mayAddAttachments(in: nil))
        XCTAssertEqual(restored.commandMessage, String(localized: "Attachments expired. Add them again before sending."))
        XCTAssertTrue(disk.load(key).draft.pending.isEmpty)
        XCTAssertEqual(disk.load(key).draft.texts, ["": original.text])
    }

    func testRejectedRestoredAttachmentRetryFindsTheDeliveredEventAndKeepsOtherText() async throws {
        let (wire, restored, original) = try await restoreAttachmentSend(delivered: true)
        defer { restored.close() }
        restored.draft = "A different draft"
        wire.latest = 1
        wire.writeFailure = BotRoomFailure(code: 4001, reason: "invalid_params")
        await restored.send(retry: true)

        XCTAssertEqual(restored.events.map(\.eventID), [original.serverEventID])
        XCTAssertNil(restored.commandMessage)
        XCTAssertNil(restored.uncertainSend)
        XCTAssertTrue(disk.load(key).draft.pending.isEmpty)
        XCTAssertEqual(disk.load(key).draft.texts, ["": "A different draft"])
    }

    func testRetryConfirmsTheSamePreviouslyCommittedAttachmentAfterAnHour() async throws {
        let (wire, restored, original) = try await restoreAttachmentSend(delivered: true)
        defer { restored.close() }
        wire.latest = 1
        await restored.send(retry: true)

        let retry = try XCTUnwrap(wire.writes.last?.1)
        XCTAssertEqual(wire.writes.count, 2)
        XCTAssertEqual(retry["event_id"]?.text, original.eventID)
        XCTAssertEqual(retry["payload"]?["thread_id"].text, original.threadID)
        XCTAssertEqual(retry["payload"]?["attachments"].list, original.attachments.map(\.json))
        XCTAssertEqual(wire.uploadCalls.count, 1)
        XCTAssertEqual(restored.events.map(\.roomAttachments), [original.attachments])
        XCTAssertNil(restored.uncertainSend)
        XCTAssertTrue(disk.load(key).draft.pending.isEmpty)
    }

    func testRoomDraftsAreIsolatedByConnectionServerAndRoom() {
        let writer = disk
        let reader = makeReader(RoomWire(), store: writer)
        reader.draft = "Private draft"
        reader.suspend()

        XCTAssertEqual(disk.load(key).draft.texts, ["": "Private draft"])
        for other in [
            BotRoomKey(server: key.server, connectionID: UUID(), roomID: key.roomID),
            BotRoomKey(server: URL(string: "https://another.example")!, connectionID: key.connectionID, roomID: key.roomID),
            BotRoomKey(server: key.server, connectionID: key.connectionID, roomID: "another-room")
        ] {
            XCTAssertTrue(disk.load(other).draft.texts.isEmpty)
        }
    }

    func testSuspendingPersistsTypingBeforeTheDebounceFires() {
        let reader = makeReader(RoomWire(), draftSaveDelay: .seconds(3600))
        reader.setDraft("typing", in: nil)
        XCTAssertEqual(reader.draft, "typing")
        XCTAssertTrue(disk.load(key).draft.texts.isEmpty)

        reader.suspend()
        XCTAssertEqual(disk.load(key).draft.texts, ["": "typing"])
        XCTAssertEqual(makeReader(RoomWire()).draft, "typing")
    }

    func testDisbandAndExpiryPurgeDraftsAndUncertainSends() async {
        for disband in [true, false] {
            let wire = RoomWire(), reader = makeReader(wire)
            await reader.open()
            reader.draft = "Pending text"
            reader.setDraft("Draft reply", in: "discussion")
            wire.writeFailure = BotFailure.transport
            await reader.send()
            XCTAssertFalse(disk.load(key).draft.pending.isEmpty)

            wire.writeFailure = nil
            if disband {
                await reader.disband()
            } else {
                wire.failure = BotRoomFailure(code: 4112, reason: "room_history_expired")
                await reader.poll()
            }
            reader.close()
            let restored = makeReader(RoomWire())
            XCTAssertNil(restored.uncertainSend)
            XCTAssertTrue(restored.draft.isEmpty)
            XCTAssertTrue(restored.draft(in: "discussion").isEmpty)
        }
    }

    func testRemovingTheBotConnectionPurgesOnlyItsDrafts() async throws {
        let server = URL(string: "https://\(UUID().uuidString.lowercased()).example")!
        let removed = BotRoomKey(server: server, connectionID: connection.id, roomID: room.id)
        let kept = BotRoomKey(server: server, connectionID: UUID(), roomID: room.id)
        let store = BotRoomDraftStore.shared
        defer { store.remove(server: server) }
        let reader = makeReader(RoomWire(), store: store, key: removed)
        reader.draft = "Remove this"
        try saveFixture(for: kept, store: store)
        let connections = BotConnectionStore(keychain: InMemoryKeychainStore())
        try connections.save(connection, server: server)
        let setup = BotConnectionSetup(server: server, isServerSignIn: false, store: connections, relay: { _ in nil })
        setup.load()

        let removedConnection = await setup.remove()
        XCTAssertTrue(removedConnection)
        reader.draft = "Late editor update"
        reader.close()

        XCTAssertTrue(store.load(removed).draft.texts.isEmpty)
        XCTAssertFalse(store.load(kept).draft.pending.isEmpty)
    }

    func testSignOutAndServerRemovalPurgeOnlyTheirServerDrafts() async throws {
        let keychain = InMemoryKeychainStore()
        let auth = AuthManager(keychain: keychain, serverRegistry: .inMemory(keychain: keychain),
                               preferences: .ephemeral(), forgetPush: { _ in })
        let store = BotRoomDraftStore.shared
        let servers = (0..<3).map { _ in URL(string: "https://\(UUID().uuidString.lowercased()).example")! }
        defer { for server in servers { store.remove(server: server) } }
        let keys = try servers.map { server in
            let saved = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
            XCTAssertTrue(auth.addHermesServer(saved, activating: server == servers[0]))
            let key = BotRoomKey(server: server, connectionID: saved.id, roomID: room.id)
            try saveFixture(for: key, store: store)
            return key
        }

        await auth.signOut()
        XCTAssertTrue(store.load(keys[0]).draft.texts.isEmpty)
        XCTAssertTrue(store.load(keys[0]).draft.pending.isEmpty)
        XCTAssertFalse(store.load(keys[1]).draft.pending.isEmpty)
        await auth.removeServer(try XCTUnwrap(auth.servers.first { $0.id == servers[1].absoluteString }))

        XCTAssertTrue(store.load(keys[1]).draft.texts.isEmpty)
        XCTAssertTrue(store.load(keys[1]).draft.pending.isEmpty)
        XCTAssertFalse(store.load(keys[2]).draft.pending.isEmpty)
    }

    private func makeReader(_ wire: RoomWire, store: BotRoomDraftStore? = nil, key: BotRoomKey? = nil,
                            now: @escaping () -> Date = Date.init,
                            draftSaveDelay: Duration = .milliseconds(200)) -> BotRoomReader {
        BotRoomReader(key: key ?? self.key, connection: connection, room: room, cache: BotHistoryCache(),
                      drafts: store ?? disk, makeWire: { _ in wire }, attachmentNow: now, draftSaveDelay: draftSaveDelay)
    }

    private func attachmentWire() -> RoomWire {
        let wire = RoomWire()
        var capabilities = RoomFixture.capabilities.fields!
        capabilities["methods"] = .array((RoomFixture.methods + [BotRoomFiles.uploadMethod]).map(BotJSON.string))
        wire.capabilities = .object(capabilities)
        return wire
    }

    private func attachFile(to reader: BotRoomReader) async {
        await reader.addAttachments([.init(name: "note.txt", load: {
            .init(data: Data("example".utf8), filename: "note.txt")
        })], in: nil)
    }

    private func restoreAttachmentSend(delivered: Bool) async throws -> (RoomWire, BotRoomReader, BotRoomReader.Send) {
        let wire = attachmentWire()
        let uploadedAt = Date(timeIntervalSince1970: 10_000)
        let reader = makeReader(wire, now: { uploadedAt })
        await reader.open()
        defer { reader.close() }
        reader.draft = "Message with attachment"
        await attachFile(to: reader)
        if delivered { wire.loseWrite = true } else { wire.writeFailure = BotFailure.transport }
        await reader.send()
        let original = try XCTUnwrap(reader.uncertainSend)
        XCTAssertEqual(original.attachments.count, 1)

        wire.latest = 0
        wire.loseWrite = false
        wire.writeFailure = nil
        let restored = makeReader(wire, now: { uploadedAt.addingTimeInterval(7_200) })
        await restored.open()
        XCTAssertTrue(restored.mayResend(in: nil))
        XCTAssertTrue(restored.attachmentChips(in: nil).isEmpty)
        XCTAssertEqual(restored.uncertainSend, original)
        return (wire, restored, original)
    }

    private func saveFixture(for key: BotRoomKey, store: BotRoomDraftStore) throws {
        let generation = store.load(key).generation
        let text = "Unconfirmed message"
        try store.save(.init(texts: ["": text], pending: [.init(text: text)]), for: key, generation: generation)
    }
}
