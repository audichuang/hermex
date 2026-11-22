import XCTest
@testable import HermesMobile

final class BotPreviewTextTests: XCTestCase {
    private func profile(id: String, title: String? = nil) throws -> BotProfile {
        var look: [String: BotJSON] = [:]
        if let title { look["title"] = .string(title) }
        return try XCTUnwrap(BotProfile(.object([
            "name": .string(id),
            "ui_meta": .object(["hermes-bots": .object(look)]),
        ])))
    }

    func testBotEmojiPrefixStripsPrefixAndResolvesSender() throws {
        let manager = try profile(id: "manager", title: "Project Manager")
        let dispatch = try profile(id: "u7e3d-u6a5f", title: "總機")
        let chief = try profile(id: "chief", title: "Chief of Staff")
        let primary = try profile(id: "default", title: "Main Agent")
        let realHermes = try profile(id: "hermes", title: "Hermes Two")

        let matched = BotPreviewText.parse(
            "Message from 🤖 manager (@manager): Learn-share: skill installed",
            roster: [manager]
        )
        XCTAssertEqual(matched, BotPreviewText(text: "Learn-share: skill installed", fromBot: "Project Manager"))
        XCTAssertEqual(matched.displayLine, "Project Manager: Learn-share: skill installed")

        let fallback = BotPreviewText.parse("Message from 🤖 manager (@manager): Learn-share: skill installed")
        XCTAssertEqual(fallback, BotPreviewText(text: "Learn-share: skill installed", fromBot: "manager"))

        let multiWord = BotPreviewText.parse(
            "Message from 🤖 Chief of Staff (@chief): **Plan**: ship `v2`",
            roster: [chief]
        )
        XCTAssertEqual(multiWord, BotPreviewText(text: "Plan: ship v2", fromBot: "Chief of Staff"))

        let multiWordFallback = BotPreviewText.parse("Message from 🤖 Chief of Staff (@chief): ready")
        XCTAssertEqual(multiWordFallback, BotPreviewText(text: "ready", fromBot: "Chief of Staff"))

        let cjk = BotPreviewText.parse(
            "Message from 🤖 舊名 (@u7e3d-u6a5f): > 任務完成",
            roster: [dispatch]
        )
        XCTAssertEqual(cjk, BotPreviewText(text: "任務完成", fromBot: "總機"))

        let defaultViaHermes = BotPreviewText.parse("Message from 🤖 Hermes (@hermes): ping", roster: [primary])
        XCTAssertEqual(defaultViaHermes.fromBot, "Main Agent")

        let explicitHermes = BotPreviewText.parse(
            "Message from 🤖 Hermes (@hermes): ping",
            roster: [primary, realHermes]
        )
        XCTAssertEqual(explicitHermes.fromBot, "Hermes Two")
    }

    func testLegacyAgentPrefixStripsPrefixAndResolvesSender() throws {
        let researcher = try profile(id: "researcher", title: "Paper Scout")
        let primary = try profile(id: "default", title: "Main Agent")

        let matched = BotPreviewText.parse(
            "Message from agent 'researcher': **Summary** in [doc](https://x.y/z)",
            roster: [researcher]
        )
        XCTAssertEqual(matched, BotPreviewText(text: "Summary in doc", fromBot: "Paper Scout"))
        XCTAssertEqual(matched.displayLine, "Paper Scout: Summary in doc")

        let fallback = BotPreviewText.parse("Message from agent 'researcher': here is the paper")
        XCTAssertEqual(fallback, BotPreviewText(text: "here is the paper", fromBot: "researcher"))

        let primaryFallback = BotPreviewText.parse("Message from agent 'default': deploy is green")
        XCTAssertEqual(primaryFallback, BotPreviewText(text: "deploy is green", fromBot: "Hermes"))

        let primaryRoster = BotPreviewText.parse(
            "message from agent 'default': deploy is green",
            roster: [primary]
        )
        XCTAssertEqual(primaryRoster, BotPreviewText(text: "deploy is green", fromBot: "Main Agent"))

        let emptyBody = BotPreviewText.parse("Message from 🤖 manager (@manager):   ")
        XCTAssertEqual(emptyBody, BotPreviewText(text: "", fromBot: "manager"))
        XCTAssertEqual(emptyBody.displayLine, "manager: …")

        let truncatedBot = BotPreviewText.parse("Message from 🤖 manager (@manag", roster: [try profile(id: "manager", title: "Project Manager")])
        XCTAssertEqual(truncatedBot, BotPreviewText(text: "", fromBot: "Project Manager"))
        XCTAssertEqual(truncatedBot.displayLine, "Project Manager: …")

        let truncatedAgent = BotPreviewText.parse("Message from agent 'researcher'", roster: [researcher])
        XCTAssertEqual(truncatedAgent, BotPreviewText(text: "", fromBot: "Paper Scout"))
        XCTAssertEqual(truncatedAgent.displayLine, "Paper Scout: …")
    }

    func testMarkdownIsFlattenedIntoSingleLine() {
        XCTAssertEqual(BotPreviewText.parse("**Plan**: ship the `thing`").text, "Plan: ship the thing")
        XCTAssertEqual(BotPreviewText.parse("> quoted wisdom").text, "quoted wisdom")
        XCTAssertEqual(BotPreviewText.parse("see [the doc](https://x.y/z) now").text, "see the doc now")
        XCTAssertEqual(BotPreviewText.parse("![chart](https://x.y/a.png) ready").text, "chart ready")
        XCTAssertEqual(BotPreviewText.parse("## Heading\nbody").text, "Heading body")
        XCTAssertEqual(
            BotPreviewText.parse("__bold__, *italic*, _under_, ~~old~~, foo_bar_baz").text,
            "bold, italic, under, old, foo_bar_baz"
        )
        XCTAssertEqual(
            BotPreviewText.parse("```swift\nlet x = 1\n```\ndone with **$100**").text,
            "done with $100"
        )
    }

    func testPlainAndEmptyPreviewsHaveNoSender() {
        let plain = BotPreviewText.parse("Can you check the vault sync?")
        XCTAssertEqual(plain, BotPreviewText(text: "Can you check the vault sync?", fromBot: nil))
        XCTAssertEqual(plain.displayLine, "Can you check the vault sync?")

        XCTAssertEqual(BotPreviewText.parse(""), BotPreviewText(text: "", fromBot: nil))
        XCTAssertEqual(BotPreviewText.parse(nil), BotPreviewText(text: "", fromBot: nil))
        XCTAssertEqual(BotPreviewText.parse("   \n\t "), BotPreviewText(text: "", fromBot: nil))
    }
}
