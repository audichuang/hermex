import XCTest
@testable import HermesMobile

@MainActor final class BotRoomUploadTests: XCTestCase {
    func testNinthAttachmentDoesNotUpload() async throws {
        let wire = RoomWire(), reader = try makeReader(wire)
        await reader.open()
        defer { reader.close() }
        await reader.addAttachments((1...9).map { input(name: "file-\($0).txt") }, in: nil)
        XCTAssertEqual(wire.uploadCalls.count, 8)
        XCTAssertEqual(reader.attachmentChips(in: nil).count, 8)
        XCTAssertNotNil(reader.attachmentNotice(in: nil))
    }

    func testOversizedFileDoesNotUpload() async throws {
        let wire = RoomWire(), reader = try makeReader(wire)
        await reader.open()
        defer { reader.close() }
        await reader.addAttachments([input(bytes: Data(count: 15_000_001))], in: nil)
        XCTAssertTrue(wire.uploadCalls.isEmpty)
        XCTAssertTrue(reader.attachmentChips(in: nil).isEmpty)
        XCTAssertNotNil(reader.attachmentNotice(in: nil))
    }

    func testCombinedLimitRejectsTheFileThatWouldExceedIt() async throws {
        let wire = RoomWire(), reader = try makeReader(wire)
        await reader.open()
        defer { reader.close() }
        await reader.addAttachments([input(name: "first.bin", bytes: Data(count: 13_000_000)),
                                     input(name: "second.bin", bytes: Data(count: 12_000_001))], in: nil)
        XCTAssertEqual(wire.uploadCalls.count, 1)
        XCTAssertEqual(reader.attachmentChips(in: nil).map(\.name), ["first.bin"])
        XCTAssertNotNil(reader.attachmentNotice(in: nil))
        XCTAssertTrue(reader.maySend)
    }

    func testKindAndMIMEFollowBytes() throws {
        let samples: [(Data, BotRoomAttachment.Kind, String)] = [
            (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), .image, "image/png"),
            (Data([0xFF, 0xD8, 0xFF]), .image, "image/jpeg"),
            (Data("GIF89a".utf8), .image, "image/gif"),
            (Data("BM".utf8), .image, "image/bmp"),
            (Data("RIFFxxxxWEBP".utf8), .image, "image/webp"),
            (Data("%PDF-1.7".utf8), .pdf, "application/pdf"),
            (Data("Just text".utf8), .file, "text/plain"),
            (Data([0x00, 0x01]), .file, "application/octet-stream"),
            (Data([0x50, 0x4B, 0x03, 0x04]), .file, "application/zip"),
            (Data([0x1F, 0x8B]), .file, "application/gzip")
        ]
        for (bytes, kind, mime) in samples {
            let upload = try BotRoomFiles.prepare(.init(data: bytes, filename: "misleading.png"))
            XCTAssertEqual(upload.kind, kind, mime)
            XCTAssertEqual(upload.mime, mime)
            XCTAssertEqual(upload.data, bytes)
        }
    }

    func testHEICBytesBecomeJPEG() throws {
        let heic = try XCTUnwrap(Data(base64Encoded: Self.heic))
        let upload = try BotRoomFiles.prepare(.init(data: heic, filename: "camera.heic"))
        XCTAssertEqual(upload.kind, .image)
        XCTAssertEqual(upload.mime, "image/jpeg")
        XCTAssertEqual(upload.name, "camera.jpg")
        XCTAssertTrue(upload.data.starts(with: [0xFF, 0xD8, 0xFF]))
    }

    func testUploadBlocksSendUntilAnAttachmentOnlyMessageCanBeAcknowledged() async throws {
        let wire = RoomWire(), reader = try makeReader(wire)
        await reader.open()
        defer { reader.close() }
        let held = expectation(description: "Upload awaiting a reply")
        var release: CheckedContinuation<Void, Never>?
        wire.beforeUploadReply = { await withCheckedContinuation { release = $0; held.fulfill() } }
        let adding = Task { await reader.addAttachments([input()], in: nil) }
        await fulfillment(of: [held], timeout: 3)
        reader.draft = "Text cannot bypass the upload"
        XCTAssertFalse(reader.maySend)
        await reader.send()
        XCTAssertTrue(wire.writes.isEmpty)
        release?.resume()
        await adding.value

        reader.draft = ""
        XCTAssertTrue(reader.maySend)
        await reader.send()
        let payload = try XCTUnwrap(wire.writes.first?.1["payload"])
        XCTAssertEqual(payload["text"].text, "")
        let attachment = try XCTUnwrap(payload["attachments"].list?.first)
        XCTAssertEqual(attachment["name"].text, "note.txt")
        XCTAssertNotNil(attachment["attachment_id"].text)
        XCTAssertEqual(reader.events.first?.roomAttachments, [BotRoomAttachment(attachment)].compactMap { $0 })
        XCTAssertTrue(reader.attachmentChips(in: nil).isEmpty)
    }

    func testOnlyTimerPollingWaitsForAnUploadReply() async throws {
        let wire = RoomWire(), reader = try makeReader(wire)
        await reader.open()
        defer { reader.close() }
        let held = expectation(description: "Upload awaiting a reply")
        var release: CheckedContinuation<Void, Never>?
        wire.beforeUploadReply = { await withCheckedContinuation { release = $0; held.fulfill() } }
        let adding = Task { await reader.addAttachments([input()], in: nil) }
        await fulfillment(of: [held], timeout: 3)

        let priorReads = wire.stateCalls
        await reader.poll()
        XCTAssertEqual(wire.stateCalls, priorReads)
        await reader.rename("Renamed Comms")
        XCTAssertEqual(wire.stateCalls, priorReads + 1, "A command must still refresh room state")

        release?.resume()
        await adding.value
        let readsAfterCommand = wire.stateCalls
        await reader.poll()
        XCTAssertEqual(wire.stateCalls, readsAfterCommand + 1)
    }

    func testAnAttachmentPreparedWhileSuspendedCanBeRetried() async throws {
        let wire = RoomWire(), reader = try makeReader(wire)
        await reader.open()
        defer { reader.close() }
        let heic = try XCTUnwrap(Data(base64Encoded: Self.heic))
        let loading = expectation(description: "Photo is still loading")
        var release: CheckedContinuation<Void, Never>?
        let photo = BotRoomFiles.Input(name: "camera.heic") {
            await withCheckedContinuation { release = $0; loading.fulfill() }
            return .init(data: heic, filename: "camera.heic")
        }
        let adding = Task { await reader.addAttachments([photo], in: nil) }
        await fulfillment(of: [loading], timeout: 3)
        let originalID = reader.attachmentChips(in: nil).first?.id
        reader.suspend()
        release?.resume()
        await adding.value

        let chip = try XCTUnwrap(reader.attachmentChips(in: nil).first)
        XCTAssertEqual(chip.id, originalID)
        guard case .failed(let file, let message) = chip.state else { return XCTFail("The photo must be retryable") }
        XCTAssertEqual(message, BotFailure.transport.localizedDescription)
        XCTAssertEqual(file.mime, "image/jpeg")
        XCTAssertEqual(chip.name, "camera.jpg")
        XCTAssertTrue(wire.uploadCalls.isEmpty)

        await reader.open()
        await reader.retryAttachment(chip.id, in: nil)
        let call = try XCTUnwrap(wire.uploadCalls.first).params()
        XCTAssertEqual(call["upload_id"]?.text, chip.id.uuidString)
        XCTAssertEqual(call["data_base64"]?.text, file.data.base64EncodedString())
        XCTAssertTrue(reader.maySend)
    }

    func testAnAttachmentPreparedAcrossAnEpochChangeCanBeRetried() async throws {
        let wire = RoomWire(), reader = try makeReader(wire)
        await reader.open()
        defer { reader.close() }
        let loading = expectation(description: "File is still loading")
        var release: CheckedContinuation<Void, Never>?
        let bytes = Data("Keep this draft file".utf8)
        let file = BotRoomFiles.Input(name: "note.txt") {
            await withCheckedContinuation { release = $0; loading.fulfill() }
            return .init(data: bytes, filename: "note.txt")
        }
        let adding = Task { await reader.addAttachments([file], in: nil) }
        await fulfillment(of: [loading], timeout: 3)
        let originalID = reader.attachmentChips(in: nil).first?.id
        wire.epoch += 1
        await reader.poll()
        release?.resume()
        await adding.value

        let chip = try XCTUnwrap(reader.attachmentChips(in: nil).first)
        XCTAssertEqual(chip.id, originalID)
        guard case .failed(_, let message) = chip.state else { return XCTFail("The file must be retryable in the new epoch") }
        XCTAssertEqual(message, BotFailure.transport.localizedDescription)
        XCTAssertTrue(wire.uploadCalls.isEmpty)

        await reader.retryAttachment(chip.id, in: nil)
        let call = try XCTUnwrap(wire.uploadCalls.first).params()
        XCTAssertEqual(call["upload_id"]?.text, chip.id.uuidString)
        XCTAssertEqual(call["data_base64"]?.text, bytes.base64EncodedString())
        XCTAssertTrue(reader.maySend)
    }

    func testRetryUploadReusesIdentityAndConvertedBytes() async throws {
        let wire = RoomWire(), reader = try makeReader(wire)
        await reader.open()
        defer { reader.close() }
        let heic = try XCTUnwrap(Data(base64Encoded: Self.heic))
        wire.uploadFailure = BotRoomFailure(code: 4001, reason: "attachment_quota", message: "Room attachment quota exceeded")
        await reader.addAttachments([input(name: "camera.heic", bytes: heic)], in: nil)

        let failed = try XCTUnwrap(reader.attachmentChips(in: nil).first)
        guard case .failed(_, let error) = failed.state else { return XCTFail("Expected an upload failure") }
        XCTAssertEqual(error, "Room attachment quota exceeded")
        XCTAssertFalse(reader.maySend)
        let first = try XCTUnwrap(wire.uploadCalls.first).params()
        XCTAssertEqual(first["mime"]?.text, "image/jpeg")
        wire.uploadFailure = nil
        await reader.retryAttachment(failed.id, in: nil)
        let second = try XCTUnwrap(wire.uploadCalls.last).params()
        XCTAssertEqual(wire.uploadCalls.count, 2)
        XCTAssertEqual(first["upload_id"], second["upload_id"])
        XCTAssertEqual(first["data_base64"], second["data_base64"])
        XCTAssertTrue(reader.maySend)
    }

    func testExpiryBlocksAnUnsentChipAndReleasesItsStateOnRemoval() async throws {
        let wire = RoomWire()
        var now = Date(timeIntervalSince1970: 10_000)
        let reader = try makeReader(wire, now: { now })
        await reader.open()
        defer { reader.close() }
        reader.draft = "A draft with an expired attachment"
        await reader.addAttachments([input()], in: nil)
        now += 54 * 60 + 59
        XCTAssertTrue(reader.maySend)
        now += 1
        XCTAssertFalse(reader.maySend)
        reader.expireAttachments(in: nil)
        let chip = try XCTUnwrap(reader.attachmentChips(in: nil).first)
        XCTAssertEqual(chip.state, .expired)
        reader.removeAttachment(chip.id, in: nil)
        XCTAssertTrue(reader.maySend)
        XCTAssertEqual(wire.uploadCalls.count, 1)
    }

    func testUncertainSendRetriesTheSameEventAndManifestEvenAfterChipExpiry() async throws {
        let wire = RoomWire()
        var now = Date(timeIntervalSince1970: 10_000)
        let reader = try makeReader(wire, now: { now })
        await reader.open()
        defer { reader.close() }
        await reader.addAttachments([input()], in: nil)
        wire.loseWrite = true
        await reader.send()
        XCTAssertNotNil(reader.uncertainSend)
        now += 7_200
        reader.expireAttachments(in: nil)
        wire.loseWrite = false
        wire.latest = 0
        await reader.open()
        wire.latest = 1
        await reader.send(retry: true)
        XCTAssertEqual(wire.writes.count, 2)
        XCTAssertEqual(wire.writes.first?.1["event_id"], wire.writes.last?.1["event_id"])
        XCTAssertEqual(wire.writes.first?.1["payload"]?["attachments"], wire.writes.last?.1["payload"]?["attachments"])
        XCTAssertEqual(reader.events.count, 1)
        XCTAssertEqual(wire.uploadCalls.count, 1)
        XCTAssertNil(reader.uncertainSend)
    }

    func testRejectedAttachmentRetryRestoresOriginalTextIfEventIsAbsent() async throws {
        let wire = RoomWire(), reader = try makeReader(wire)
        await reader.open()
        defer { reader.close() }
        reader.draft = "Keep these words"
        await reader.addAttachments([input()], in: nil)
        wire.writeFailure = BotFailure.transport
        await reader.send()
        XCTAssertNotNil(reader.uncertainSend)
        reader.draft = ""
        wire.writeFailure = BotRoomFailure(code: 4001, reason: "invalid_params")
        let readsBeforeRetry = wire.stateCalls
        await reader.send(retry: true)
        XCTAssertGreaterThan(wire.stateCalls, readsBeforeRetry)
        XCTAssertEqual(reader.draft, "Keep these words")
        XCTAssertTrue(reader.attachmentChips(in: nil).isEmpty)
        XCTAssertNil(reader.uncertainSend)
        XCTAssertNotNil(reader.commandMessage)
        XCTAssertTrue(reader.maySend)
    }

    func testRejectedAttachmentRetryPublishesTheAlreadyCommittedEventWithoutRestoringText() async throws {
        let wire = RoomWire(), reader = try makeReader(wire)
        await reader.open()
        defer { reader.close() }
        reader.draft = "Already delivered"
        await reader.addAttachments([input()], in: nil)
        wire.loseWrite = true
        await reader.send()
        let pending = try XCTUnwrap(reader.uncertainSend)
        wire.loseWrite = false
        wire.latest = 0
        await reader.open()
        reader.draft = "An unrelated draft"
        XCTAssertTrue(reader.events.isEmpty)
        wire.latest = 1
        wire.writeFailure = BotRoomFailure(code: 4001, reason: "invalid_params")
        await reader.send(retry: true)
        XCTAssertEqual(reader.events.map(\.eventID), [pending.serverEventID])
        XCTAssertEqual(reader.draft, "An unrelated draft")
        XCTAssertTrue(reader.attachmentChips(in: nil).isEmpty)
        XCTAssertNil(reader.uncertainSend)
        XCTAssertNil(reader.commandMessage)
        await reader.send(retry: true)
        XCTAssertEqual(wire.writes.count, 2)
    }

    func testRejectedAttachmentRetryClearsTheDeliveredDraftSoSendCannotDuplicateIt() async throws {
        let wire = RoomWire(), reader = try makeReader(wire)
        await reader.open()
        defer { reader.close() }
        reader.draft = "Already delivered"
        await reader.addAttachments([input()], in: nil)
        wire.loseWrite = true
        await reader.send()
        let pending = try XCTUnwrap(reader.uncertainSend)
        wire.loseWrite = false
        wire.latest = 0
        await reader.open()
        wire.latest = 1
        wire.writeFailure = BotRoomFailure(code: 4001, reason: "invalid_params")
        await reader.send(retry: true)

        XCTAssertEqual(reader.events.map(\.eventID), [pending.serverEventID])
        XCTAssertNil(reader.uncertainSend)
        XCTAssertTrue(reader.draft.isEmpty)
        XCTAssertFalse(reader.maySend)
        wire.writeFailure = nil
        await reader.send()
        XCTAssertEqual(wire.writes.count, 2)
    }

    func testStandaloneAttachmentRetryUnlocksDraftOnlyForARefusalBeforeAdmission() async throws {
        let socket = BotScriptedSocket()
        let server = URL(string: "https://room-upload-fixture.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let http = HermesConnection(connection: connection, configuration: HermesHostFixture.configuration { _ in nil },
                                   gateway: .init(socketFactory: { _ in socket }))
        defer { HermesHostFixture.reset() }
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 0)))
        let key = BotRoomKey(server: server, connectionID: connection.id, roomID: room.id)
        var now = Date(timeIntervalSince1970: 10_000)
        let reader = BotRoomReader(key: key, connection: connection, room: room, cache: BotHistoryCache(),
                                   makeWire: { _ in BotClient(http: http) }, attachmentNow: { now })
        let capabilities = uploadCapabilities
        let bytes = Data("Room attachment".utf8)
        var sendError: BotJSON?
        socket.reply = { request in
            let result: BotJSON
            switch request["method"].text {
            case "groups.capabilities": result = capabilities
            case "groups.state":
                result = .object(["room": RoomFixture.room(latest: 0), "driver_status": RoomFixture.status()])
            case "groups.log": result = RoomFixture.page([], cursor: 0)
            case BotRoomFiles.uploadMethod:
                let params = request["params"]
                result = .object(["attachment_id": .string("att_0123456789abcdef0123456789abcdef"),
                                  "kind": params["kind"], "name": params["name"], "mime": params["mime"],
                                  "size": .number(Double(bytes.count))])
            case "groups.send":
                if let sendError { return .object(["id": request["id"], "error": sendError]) }
                result = .object([:])
            default:
                XCTFail("Unexpected room method: \(request["method"])")
                result = .null
            }
            return .object(["id": request["id"], "result": result])
        }
        await reader.open()
        defer { reader.close() }
        reader.draft = "Retry these words"
        await reader.addAttachments([input(bytes: bytes)], in: nil)
        await reader.send()
        let pending = try XCTUnwrap(reader.uncertainSend)
        now += 7_200
        reader.expireAttachments(in: nil)

        sendError = .object(["code": .number(5112)])
        await reader.send(retry: true)
        XCTAssertEqual(reader.uncertainSend, pending)
        XCTAssertFalse(reader.mayEditDraft(in: nil))

        sendError = .object(["code": .number(5112), "message": .string("attachment has expired"),
                             "data": .object(["admitted": .bool(false)])])
        await reader.send(retry: true)
        XCTAssertNil(reader.uncertainSend)
        XCTAssertTrue(reader.attachmentChips(in: nil).isEmpty)
        XCTAssertEqual(reader.draft, "Retry these words")
        XCTAssertTrue(reader.mayAddAttachments(in: nil))
    }

    func testRejectedAttachmentRetryStaysUncertainIfTheLogCannotBeChecked() async throws {
        let wire = RoomWire(), reader = try makeReader(wire)
        await reader.open()
        defer { reader.close() }
        reader.draft = "Check the room first"
        await reader.addAttachments([input()], in: nil)
        wire.writeFailure = BotFailure.transport
        await reader.send()
        let pending = try XCTUnwrap(reader.uncertainSend)
        wire.writeFailure = BotRoomFailure(code: 4001, reason: "invalid_params")
        wire.failure = BotFailure.transport
        await reader.send(retry: true)
        XCTAssertEqual(reader.uncertainSend, pending)
        XCTAssertFalse(reader.attachmentChips(in: nil).isEmpty)
    }

    func testAttachmentsStayWithTheirComposerThread() async throws {
        let wire = RoomWire(), reader = try makeReader(wire)
        wire.latest = 1
        wire.roomEvents[1] = RoomFixture.attachmentEvent(1, text: "Thread root", threadID: "thread", files: [])
        await reader.open()
        defer { reader.close() }
        await reader.addAttachments([input(name: "overview.txt")], in: nil)
        await reader.addAttachments([input(name: "thread.txt")], in: "thread")
        await reader.send(threadID: "thread")
        XCTAssertTrue(reader.attachmentChips(in: "thread").isEmpty)
        XCTAssertEqual(reader.attachmentChips(in: nil).map(\.name), ["overview.txt"])
        XCTAssertEqual(reader.events.last?.roomAttachments.first?.name, "thread.txt")
    }

    func testUploadCapabilityControlsWhetherComposerCreatesAnAttachmentButton() async throws {
        let wire = RoomWire(), reader = try makeReader(wire, uploadEnabled: false)
        await reader.open()
        defer { reader.close() }
        let composer = BotRoomComposerView(reader: reader, roster: [], avatars: [:])
        XCTAssertNil(composer.attachmentButton)
        await reader.addAttachments([input()], in: nil)
        XCTAssertTrue(wire.uploadCalls.isEmpty)

        wire.capabilities = uploadCapabilities
        await reader.open()
        XCTAssertNotNil(composer.attachmentButton)
    }

    private func makeReader(_ wire: RoomWire, uploadEnabled: Bool = true, now: @escaping () -> Date = Date.init) throws -> BotRoomReader {
        let server = URL(string: "https://room-upload-fixture.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: wire.latest)))
        if uploadEnabled { wire.capabilities = uploadCapabilities }
        let key = BotRoomKey(server: server, connectionID: connection.id, roomID: room.id)
        return BotRoomReader(key: key, connection: connection, room: room, cache: BotHistoryCache(), makeWire: { _ in wire },
                             attachmentNow: now)
    }

    private var uploadCapabilities: BotJSON {
        var capabilities = RoomFixture.capabilities.fields!
        capabilities["methods"] = .array((RoomFixture.methods + [BotRoomFiles.uploadMethod]).map(BotJSON.string))
        return .object(capabilities)
    }

    private func input(name: String = "note.txt", bytes: Data = Data("Hello from the room".utf8)) -> BotRoomFiles.Input {
        .init(.init(data: bytes, filename: name))
    }

    private static let heic = "AAAAJGZ0eXBoZWljAAAAAG1pZjFNaVBybWlhZk1pSEJoZWljAAABhm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAHBpY3QAAAAAAAAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAADnBpdG0AAAAAAAEAAAAjaWluZgAAAAAAAQAAABVpbmZlAgAAAAABAABodmMxAAAAAOZpcHJwAAAAxWlwY28AAAATY29scm5jbHgAAgACAAaAAAAADGNsbGkAywBAAAAAFGlzcGUAAAAAAAAAEAAAABAAAAAJaXJvdAAAAAAQcGl4aQAAAAADCAgIAAAAcWh2Y0MBA3AAAACwAAAAAAAe8AD8/fj4AAALA6AAAQAXQAEMAf//A3AAAAMAsAAAAwAAAwAecCShAAEAI0IBAQNwAAADALAAAAMAAAMAHqAQIEHBzDOIeSRZVNwICBgCogABAAlEAcBhckIQFMkAAAAZaXBtYQAAAAAAAAABAAEGgQIDBYaEAAAAHmlsb2MAAAAARAAAAQABAAAAAQAAAboAAAAqAAAAAW1kYXQAAAAAAAAAOgAAACYoAa/gKpDmf/7tZ//7cv2X6Av39E1ZcqET5EyPviX3/+mTGw+RTA=="
}
