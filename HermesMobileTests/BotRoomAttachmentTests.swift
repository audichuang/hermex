import Observation
import UIKit
import XCTest
@testable import HermesMobile

@MainActor final class BotRoomAttachmentTests: XCTestCase {
    func testIncompleteAndUnknownAttachmentsStillHaveFileCards() throws {
        let event = RoomFixture.attachmentEvent(1, files: [
            .object(["kind": .string("future"), "name": .string("Archive")]),
            .object(["attachment_id": .string("accessible")]),
            .null
        ])
        let files = try XCTUnwrap(BotRoomEvent(event)).roomAttachments
        XCTAssertEqual(files.count, 2)
        let unknown = try XCTUnwrap(files.first)
        XCTAssertEqual(unknown.kind, .file)
        XCTAssertEqual(unknown.displayName, "Archive")
        XCTAssertNil(unknown.size)
        XCTAssertNil(unknown.mime)
        XCTAssertFalse(unknown.canPreview)
        XCTAssertNil(BotRoomAttachment.Request(eventID: "event:1", attachment: unknown))
        let incomplete = try XCTUnwrap(files.last)
        XCTAssertFalse(incomplete.displayName.isEmpty)
        XCTAssertNotNil(BotRoomAttachment.Request(eventID: "event:1", attachment: incomplete))
    }

    func testUserAndMemberFilesUseTheirOwnEventAndAttachmentOnlyRootHasATitle() async throws {
        let wire = RoomWire()
        let pdf = RoomFixture.attachment("brief", kind: "pdf", name: "brief.pdf")
        wire.latest = 3
        wire.roomEvents = [
            1: RoomFixture.attachmentEvent(1, threadID: "first-thread", files: [pdf]),
            2: RoomFixture.attachmentEvent(2, kind: "message.member", threadID: "first-thread", files: [pdf]),
            3: RoomFixture.attachmentEvent(3, threadID: "second-thread", files: [pdf, RoomFixture.attachment("map")])
        ]
        wire.attachmentReply = { Self.result(id: $0, data: Data([1])) }
        let reader = try makeReader(wire)
        defer { reader.close() }
        await reader.open()
        XCTAssertEqual(reader.events.map(\.kind), ["message.user", "message.member", "message.user"])
        XCTAssertFalse(reader.showsWelcome)
        let first = try XCTUnwrap(reader.threads.first { $0.id == "first-thread" })
        XCTAssertEqual(BotRoomThreadPreview(thread: first, reader: reader).rootTitle, "brief.pdf")
        let second = try XCTUnwrap(reader.threads.first { $0.id == "second-thread" })
        let title = try XCTUnwrap(BotRoomThreadPreview(thread: second, reader: reader).rootTitle)
        XCTAssertTrue(title.hasPrefix("brief.pdf"))
        XCTAssertTrue(title.contains("2"))

        let stateCalls = wire.stateCalls
        for event in first.events {
            let request = try XCTUnwrap(reader.attachmentLists[event.seq]?.files.first?.request)
            let data = try await reader.downloadAttachment(request)
            XCTAssertEqual(data, Data([1]))
        }
        XCTAssertEqual(wire.attachmentCalls, [
            .groupsAttachmentDownload(roomID: "fixture-room", eventID: "event:1", attachmentID: "brief"),
            .groupsAttachmentDownload(roomID: "fixture-room", eventID: "event:2", attachmentID: "brief")
        ])
        XCTAssertEqual(wire.stateCalls, stateCalls, "Downloading does not trigger a poll")
    }

    func testLargeAndUnsizedFilesRemainVisibleWithTheirDownloadLimits() async throws {
        let wire = RoomWire()
        wire.latest = 1
        wire.roomEvents[1] = RoomFixture.attachmentEvent(1, files: [
            RoomFixture.attachment("too-large", size: 12_000_001),
            RoomFixture.attachment("large-image", size: 6 * 1024 * 1024),
            RoomFixture.attachment("unsized", size: nil)
        ])
        wire.attachmentReply = { Self.result(id: $0, data: Data([1])) }
        let reader = try makeReader(wire)
        defer { reader.close() }
        await reader.open()
        let files = try XCTUnwrap(reader.attachmentLists[1]?.files)
        XCTAssertEqual(files.count, 3)
        XCTAssertTrue(files[0].attachment.exceedsDownloadLimit)
        XCTAssertNil(files[0].request)
        XCTAssertFalse(files.contains { $0.attachment.canPreview })
        XCTAssertTrue(wire.attachmentCalls.isEmpty)

        for file in files.dropFirst() {
            let request = try XCTUnwrap(file.request)
            _ = try await reader.downloadAttachment(request)
        }
        XCTAssertEqual(wire.attachmentCalls, [
            .groupsAttachmentDownload(roomID: "fixture-room", eventID: "event:1", attachmentID: "large-image"),
            .groupsAttachmentDownload(roomID: "fixture-room", eventID: "event:1", attachmentID: "unsized")
        ])
    }

    func testMissingDownloadCapabilityKeepsTheManifestReadOnly() async throws {
        let wire = RoomWire()
        wire.latest = 1
        wire.roomEvents[1] = RoomFixture.attachmentEvent(1, files: [RoomFixture.attachment("map")])
        let reader = try makeReader(wire, downloadEnabled: false)
        defer { reader.close() }
        await reader.open()
        XCTAssertFalse(reader.mayDownload)
        let file = try XCTUnwrap(reader.attachmentLists[1]?.files.first)
        let request = try XCTUnwrap(file.request)
        reader.previewAttachment(request, namespace: "fixture", observer: UUID()) { _ in
            XCTFail("A server without the method cannot provide an image")
        }
        do {
            _ = try await reader.downloadAttachment(request)
            XCTFail("A server without the method cannot provide a file")
        } catch {
            XCTAssertTrue(wire.attachmentCalls.isEmpty)
        }
    }

    func testPreviewQueueSharesDownloadsDropsDepartedRowsAndLetsManualDownloadsThrough() async throws {
        let wire = RoomWire()
        let initial = expectation(description: "two automatic downloads entered the wire")
        initial.expectedFulfillmentCount = 2
        let next = expectation(description: "next visible preview entered the wire")
        let last = expectation(description: "last preview entered after the one ahead of it")
        let manual = expectation(description: "manual download entered while both slots were occupied")
        let probe = DownloadProbe { id in
            switch id {
            case "a", "b": initial.fulfill()
            case "d": next.fulfill()
            case "f": last.fulfill()
            case "e": manual.fulfill()
            default: XCTFail("Unexpected request for \(id)")
            }
        }
        wire.attachmentReply = { await probe.reply(to: $0) }
        let reader = try makeReader(wire)
        defer { reader.close(); probe.finish() }
        await reader.open()
        let shared = expectation(description: "second observer got the shared preview")
        let promoted = expectation(description: "the queued preview joined the manual download")
        let namespace = UUID().uuidString
        let a = try request("a"), e = try request("e")
        let departed = UUID(), first = UUID()
        reader.previewAttachment(a, namespace: namespace, observer: first) { _ in XCTFail("First observer left") }
        reader.previewAttachment(try request("b"), namespace: namespace, observer: UUID()) { _ in }
        reader.previewAttachment(a, namespace: namespace, observer: UUID()) { image in
            XCTAssertNotNil(image)
            shared.fulfill()
        }
        reader.previewAttachment(try request("c"), namespace: namespace, observer: departed) { _ in
            XCTFail("A queued row left before its turn")
        }
        reader.previewAttachment(try request("d"), namespace: namespace, observer: UUID()) { _ in }
        reader.previewAttachment(try request("f"), namespace: namespace, observer: UUID()) { _ in }
        reader.previewAttachment(e, namespace: namespace, observer: UUID()) { image in
            XCTAssertNotNil(image)
            promoted.fulfill()
        }
        reader.cancelAttachmentPreview(observer: first)
        reader.cancelAttachmentPreview(observer: departed)
        await fulfillment(of: [initial], timeout: 3)
        XCTAssertEqual(wire.attachmentCalls.count, 2)

        let manualTask = Task { try await reader.downloadAttachment(e) }
        await fulfillment(of: [manual], timeout: 3)
        XCTAssertEqual(wire.attachmentCalls.count, 3)
        probe.release("e")
        let data = try await manualTask.value
        XCTAssertEqual(data, probe.imageData)
        await fulfillment(of: [promoted], timeout: 3)
        XCTAssertEqual(wire.attachmentCalls.count, 3, "Releasing a manual download does not open a preview slot")

        probe.release("a")
        await fulfillment(of: [shared, next], timeout: 3)
        XCTAssertEqual(wire.attachmentCalls.count, 4)
        probe.release("b")
        await fulfillment(of: [last], timeout: 3)
        XCTAssertEqual(wire.attachmentCalls.count, 5)

        let fromCache = expectation(description: "the previously started preview is cached")
        reader.previewAttachment(a, namespace: namespace, observer: UUID()) { image in
            XCTAssertNotNil(image)
            fromCache.fulfill()
        }
        probe.release("d"); probe.release("f")
        await fulfillment(of: [fromCache], timeout: 3)
        XCTAssertEqual(wire.attachmentCalls.count, 5)
    }

    func testPollWithoutNewVisibleEventsDoesNotRepublishAttachmentLists() async throws {
        let wire = RoomWire()
        wire.latest = 1
        wire.roomEvents[1] = RoomFixture.attachmentEvent(1, files: [RoomFixture.attachment("map")])
        let reader = try makeReader(wire)
        defer { reader.close() }
        await reader.open()
        let initial = reader.attachmentLists
        XCTAssertFalse(initial.isEmpty)
        let changed = expectation(description: "attachment lists were assigned again")
        withObservationTracking { _ = reader.attachmentLists } onChange: { changed.fulfill() }

        await reader.poll()
        wire.latest = 2
        wire.kind = "future.event"
        await reader.poll()
        XCTAssertEqual(reader.attachmentLists, initial)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0), .timedOut)
    }

    private func makeReader(_ wire: RoomWire, downloadEnabled: Bool = true) throws -> BotRoomReader {
        let server = try XCTUnwrap(URL(string: "https://room-fixture.example"))
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: wire.latest)))
        if downloadEnabled {
            var capabilities = try XCTUnwrap(RoomFixture.capabilities.fields)
            capabilities["methods"] = .array((RoomFixture.methods + [BotRoomAttachment.downloadMethod]).map(BotJSON.string))
            wire.capabilities = .object(capabilities)
        }
        let key = BotRoomKey(server: server, connectionID: connection.id, roomID: room.id)
        return BotRoomReader(key: key, connection: connection, room: room, cache: BotHistoryCache(), makeWire: { _ in wire })
    }

    private func request(_ id: String) throws -> BotRoomAttachment.Request {
        let attachment = try XCTUnwrap(BotRoomAttachment(RoomFixture.attachment(id)))
        return try XCTUnwrap(BotRoomAttachment.Request(eventID: "event:1", attachment: attachment))
    }

    fileprivate static func result(id: String, data: Data) -> BotJSON {
        var fields = RoomFixture.attachment(id, size: data.count).fields!
        fields["data_base64"] = .string(data.base64EncodedString())
        return .object(fields)
    }
}

@MainActor private final class DownloadProbe {
    private var pending: [String: [CheckedContinuation<BotJSON, Never>]] = [:]
    private var released = Set<String>()
    private var finished = false
    private let onCall: (String) -> Void
    let imageData = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).pngData { context in
        UIColor.systemBlue.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
    }

    init(onCall: @escaping (String) -> Void) { self.onCall = onCall }

    func reply(to id: String) async -> BotJSON {
        if finished || released.contains(id) { return BotRoomAttachmentTests.result(id: id, data: imageData) }
        return await withCheckedContinuation {
            pending[id, default: []].append($0)
            onCall(id)
        }
    }

    func release(_ id: String) {
        released.insert(id)
        let reply = BotRoomAttachmentTests.result(id: id, data: imageData)
        for continuation in pending.removeValue(forKey: id) ?? [] { continuation.resume(returning: reply) }
    }

    func finish() {
        finished = true
        for id in Array(pending.keys) { release(id) }
    }
}
