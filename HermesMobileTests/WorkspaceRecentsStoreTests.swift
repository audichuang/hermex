import XCTest
@testable import HermesMobile

final class WorkspaceRecentsStoreTests: XCTestCase {
    private let serverA = URL(string: "https://a.example")!
    private let serverB = URL(string: "https://b.example")!

    func testRecordMovesPathToFrontAndLimitsToFive() {
        let store = WorkspaceRecentsStore(keychain: InMemoryKeychainStore())

        store.record("/one", server: serverA, profileName: "work")
        store.record("/two", server: serverA, profileName: "work")
        store.record("/three", server: serverA, profileName: "work")
        store.record("/four", server: serverA, profileName: "work")
        store.record("/five", server: serverA, profileName: "work")
        store.record("/six", server: serverA, profileName: "work")
        store.record("/two", server: serverA, profileName: "work")

        XCTAssertEqual(
            store.recents(server: serverA, profileName: "work"),
            ["/two", "/six", "/five", "/four", "/three"]
        )
    }

    func testRecentsAreIsolatedByServerAndProfile() {
        let store = WorkspaceRecentsStore(keychain: InMemoryKeychainStore())

        store.record("/a-work", server: serverA, profileName: "work")
        store.record("/a-home", server: serverA, profileName: "home")
        store.record("/b-work", server: serverB, profileName: "work")

        XCTAssertEqual(store.recents(server: serverA, profileName: "work"), ["/a-work"])
        XCTAssertEqual(store.recents(server: serverA, profileName: "home"), ["/a-home"])
        XCTAssertEqual(store.recents(server: serverB, profileName: "work"), ["/b-work"])
    }

    func testUndeterminedScopeDoesNotReadOtherRecents() {
        let store = WorkspaceRecentsStore(keychain: InMemoryKeychainStore())
        store.record("/a-work", server: serverA, profileName: "work")

        XCTAssertEqual(store.recents(server: nil, profileName: "work"), [])
        XCTAssertEqual(store.recents(server: serverA, profileName: nil), [])
        XCTAssertEqual(store.recents(server: serverA, profileName: "   "), [])
        XCTAssertEqual(store.record("/ignored", server: serverA, profileName: nil), [])
    }

    func testTrustedRootCheckUsesExactPathIdentity() {
        let roots = [
            WorkspaceRoot(path: "/Users/a/src", name: "src"),
            WorkspaceRoot(path: "/tmp/work", name: "work"),
        ]

        XCTAssertTrue(WorkspaceRecentsStore.isWithinTrustedRoots("/Users/a/src", roots: roots))
        XCTAssertTrue(WorkspaceRecentsStore.isWithinTrustedRoots("/Users/a/src/hermex", roots: roots))
        XCTAssertFalse(WorkspaceRecentsStore.isWithinTrustedRoots("/Users/a/src-other", roots: roots))
        XCTAssertFalse(WorkspaceRecentsStore.isWithinTrustedRoots("/Users/a/SRC", roots: roots))
    }
}

final class ComposerWorkspacePickerContentTests: XCTestCase {
    private let roots = [
        WorkspaceRoot(path: "/Users/a/src/hermex", name: "Hermex"),
        WorkspaceRoot(path: "/Users/a/src/leet", name: "LEET"),
        WorkspaceRoot(path: "/tmp/work", name: "work"),
    ]

    func testNameAndPathFragmentsFilterLocalCandidatesImmediately() {
        let content = ComposerWorkspacePickerContent.make(
            query: "  leet  ",
            currentPath: "/Users/a/src/hermex",
            savedRoots: roots,
            recentPaths: ["/tmp/work"],
            suggestions: ["/Users/a/src/leetcode"]
        )

        XCTAssertNil(content.current)
        XCTAssertTrue(content.recents.isEmpty)
        XCTAssertEqual(content.saved.map(\.path), ["/Users/a/src/leet"])
        XCTAssertEqual(content.suggestions.map(\.path), ["/Users/a/src/leetcode"])
    }

    func testCurrentPathAppearsOnceWithFriendlyName() {
        let content = ComposerWorkspacePickerContent.make(
            query: "",
            currentPath: "/Users/a/src/hermex",
            savedRoots: roots,
            recentPaths: ["/Users/a/src/hermex", "/tmp/work"],
            suggestions: ["/Users/a/src/hermex", "/opt/other"]
        )

        XCTAssertEqual(content.current?.path, "/Users/a/src/hermex")
        XCTAssertEqual(content.current?.name, "Hermex")
        XCTAssertEqual(content.current?.displayName, "Hermex")
        XCTAssertTrue(content.current?.isCurrent == true)
        XCTAssertEqual(content.recents.map(\.path), ["/tmp/work"])
        XCTAssertEqual(content.saved.map(\.path), ["/Users/a/src/leet"])
        XCTAssertEqual(content.suggestions.map(\.path), ["/opt/other"])
    }

    func testEmptyQueryKeepsLocalResultsWithoutSuggestions() {
        let content = ComposerWorkspacePickerContent.make(
            query: "",
            currentPath: "/tmp/work",
            savedRoots: roots,
            recentPaths: ["/tmp/work"],
            suggestions: []
        )

        XCTAssertTrue(content.hasLocalMatches)
        XCTAssertEqual(content.current?.path, "/tmp/work")
        XCTAssertTrue(content.recents.isEmpty)
        XCTAssertEqual(content.saved.map(\.path), ["/Users/a/src/hermex", "/Users/a/src/leet"])
        XCTAssertTrue(content.suggestions.isEmpty)
    }
}
