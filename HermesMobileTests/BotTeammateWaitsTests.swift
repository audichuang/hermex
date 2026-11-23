import XCTest
@testable import HermesMobile

@MainActor final class BotTeammateWaitsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let suite = "BotTeammateWaitsTests." + UUID().uuidString
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func row(_ id: String, state: String, _ extra: [String: BotJSON] = [:]) -> BotJSON {
        .object(["delivery_id": .string(id), "target": .string("scout"), "target_handle": .string("Scout"),
                 "state": .string(state), "since": .number(1_000), "preview": .string("hi")]
            .merging(extra) { $1 })
    }

    private func answer(_ rows: [BotJSON]) -> BotJSON {
        .object(["sender": .string("hermes"), "deliveries": .array(rows)])
    }

    private func waits(_ defaults: UserDefaults, connection: UUID = UUID(),
                       load: @escaping @MainActor () async throws -> BotJSON) -> BotTeammateWaits {
        BotTeammateWaits(connectionID: connection, store: .init(defaults: defaults), load: load)
    }

    func testEachStateReadsAsItsLabel() async throws {
        let rows: [BotJSON] = [
            row("1", state: "queued"), row("2", state: "claimed"), row("3", state: "working"),
            row("4", state: "waiting_on_you", ["waiting_on": .string("approval")]),
            row("5", state: "waiting_on_you"),
            row("6", state: "waiting_on_you", ["waiting_on": .string("clarify")]),
            row("7", state: "failed", ["reason": .string("provider_rate_limit")]),
            row("8", state: "failed", ["reason": .string("some_new_code"), "error": .string("disk full")]),
            row("9", state: "failed", ["reason": .string("some_new_code")]),
            row("10", state: "failed", ["reason": .string("unknown_outcome"), "error": .string("gone")]),
            row("11", state: "failed", ["reason": .string("unknown")]),
        ]
        let model = waits(try defaults()) { self.answer(rows) }
        await model.refresh()
        XCTAssertEqual(model.visibleRows.map(\.label), [
            .queued, .pickedUp, .working, .approveOrDeny, .answerQuestion, .answerQuestion,
            .failed(.known("provider_rate_limit")), .failed(.verbatim("disk full")), .failed(.unknown),
            .outcomeUnknown, .failed(.unknown),
        ])
        XCTAssertTrue(model.showsNeverResent)
        for row in model.visibleRows {
            if case .failed(.verbatim(let text)) = row.label { XCTAssertNotEqual(text, row.reason) }
            if case .failed(.known(let code)) = row.label { XCTAssertTrue(BotTeammateDelivery.knownReasons.contains(code)) }
        }
        XCTAssertEqual(model.visibleRows[0].teammateName, "Scout")
    }

    func testUnknownFieldsAndStatesDoNotBreakTheList() async throws {
        let rows: [BotJSON] = [
            row("1", state: "working", ["brand_new_field": .object(["x": .bool(true)])]),
            row("2", state: "teleporting"),
            .object(["target": .string("scout"), "state": .string("queued")]),
            row("4", state: "queued"),
        ]
        let model = waits(try defaults()) { self.answer(rows) }
        await model.refresh()
        XCTAssertEqual(model.visibleRows.map(\.id), ["1", "4"])
    }

    func testAHostWithoutTheMethodShowsNoCardAndIsNotAskedAgain() async throws {
        var calls = 0
        var failure: Error = BotFailure.rejected(-32601)
        let model = waits(try defaults()) { calls += 1; throw failure }
        await model.refresh()
        XCTAssertTrue(model.visibleRows.isEmpty)
        XCTAssertTrue(model.isUnsupported)
        await model.refresh()
        XCTAssertEqual(calls, 1)

        failure = BotSettingFailure.rejected(-32601, "unknown method")
        let other = waits(try defaults()) { calls += 1; throw failure }
        await other.refresh()
        await other.refresh()
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(other.isUnsupported)
    }

    func testAFailedRefreshKeepsTheLastRowsAndMarksThemStale() async throws {
        var reply: Result<BotJSON, Error> = .success(answer([row("1", state: "working")]))
        let model = waits(try defaults()) { try reply.get() }
        await model.refresh()
        XCTAssertFalse(model.isStale)

        reply = .failure(BotFailure.transport)
        await model.refresh()
        XCTAssertEqual(model.visibleRows.map(\.id), ["1"])
        XCTAssertTrue(model.isStale)
        XCTAssertFalse(model.isUnsupported)

        reply = .success(answer([row("1", state: "working"), row("2", state: "queued")]))
        await model.refresh()
        XCTAssertFalse(model.isStale)
        XCTAssertEqual(model.visibleRows.map(\.id), ["1", "2"])
    }

    func testAStaleSocketBeforeAnyLoadIsNotAFailure() async throws {
        let model = waits(try defaults()) { throw BotFailure.stale }
        await model.refresh()
        XCTAssertFalse(model.isStale)
        XCTAssertFalse(model.isUnsupported)
    }

    func testADisconnectAfterASuccessfulLoadKeepsTheRowsAndMarksThemStale() async throws {
        var reply: Result<BotJSON, Error> = .success(answer([row("1", state: "working")]))
        let model = waits(try defaults()) { try reply.get() }
        await model.refresh()

        reply = .failure(BotFailure.stale)
        await model.refresh()
        XCTAssertTrue(model.isStale)
        XCTAssertFalse(model.isUnsupported)
        XCTAssertEqual(model.visibleRows.map(\.id), ["1"])
    }

    func testOnlyAFailureCanBeDismissedAndOnlyOnItsOwnConnection() async throws {
        let shared = try defaults()
        var rows = [row("w", state: "working"), row("f", state: "failed", ["reason": .string("cancelled")])]
        let connection = UUID()
        let model = waits(shared, connection: connection) { self.answer(rows) }
        await model.refresh()

        model.dismiss("w")
        XCTAssertEqual(model.visibleRows.map(\.id), ["w", "f"])
        rows = [row("w", state: "failed", ["reason": .string("cancelled")]), rows[1]]
        await model.refresh()
        XCTAssertEqual(model.visibleRows.map(\.id), ["w", "f"], "Dismissing a row that had not failed must not hide its later failure")
        model.dismiss("f")
        XCTAssertEqual(model.visibleRows.map(\.id), ["w"])

        rows[0] = row("w", state: "working")
        let reopened = waits(shared, connection: connection) { self.answer(rows) }
        await reopened.refresh()
        XCTAssertEqual(reopened.visibleRows.map(\.id), ["w"], "A dismissal outlives the chat")

        let otherServer = waits(shared, connection: UUID()) { self.answer(rows) }
        await otherServer.refresh()
        XCTAssertEqual(otherServer.visibleRows.map(\.id), ["w", "f"])
    }

    func testTheRequestNamesOnlyTheBotsProfile() throws {
        let call = HermesCall.botDeliveryList(profile: "hermes")
        XCTAssertEqual(call.method, "bot_delivery.list")
        XCTAssertEqual(try call.params(), ["profile": .string("hermes")])
        XCTAssertThrowsError(try HermesCall.botDeliveryList(profile: "").params())
    }
}
