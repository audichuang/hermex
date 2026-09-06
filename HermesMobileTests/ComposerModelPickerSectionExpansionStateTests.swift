import XCTest
@testable import HermesMobile

final class ComposerModelPickerSectionExpansionStateTests: XCTestCase {
    func testSectionsStartCollapsedWhenSearchIsEmpty() {
        let state = ComposerModelPickerSectionExpansionState()

        XCTAssertFalse(state.isExpanded(groupID: "openai"))
    }

    func testDefaultExpandedGroupIsExpandedWhenSearchIsEmpty() {
        let state = ComposerModelPickerSectionExpansionState()

        XCTAssertTrue(state.isExpanded(groupID: "openai", defaultExpandedGroupID: "openai"))
        XCTAssertFalse(state.isExpanded(groupID: "anthropic", defaultExpandedGroupID: "openai"))
    }

    func testManualCollapseOverridesDefaultExpandedGroup() {
        var state = ComposerModelPickerSectionExpansionState()

        state.setExpanded(false, groupID: "openai")

        XCTAssertFalse(state.isExpanded(groupID: "openai", defaultExpandedGroupID: "openai"))
    }

    func testManualExpansionPersistsWhileSearchIsEmpty() {
        var state = ComposerModelPickerSectionExpansionState()

        state.setExpanded(true, groupID: "openai")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))

        state.setExpanded(false, groupID: "openai")

        XCTAssertFalse(state.isExpanded(groupID: "openai"))
    }

    func testSearchAutoExpandsAllSections() {
        var state = ComposerModelPickerSectionExpansionState()

        state.updateSearchText("gpt")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
        XCTAssertTrue(state.isExpanded(groupID: "anthropic"))
    }

    func testManualCollapseDuringSearchDoesNotChangeEmptySearchState() {
        var state = ComposerModelPickerSectionExpansionState()
        state.setExpanded(true, groupID: "openai")
        state.updateSearchText("gpt")

        state.setExpanded(false, groupID: "openai")

        XCTAssertFalse(state.isExpanded(groupID: "openai"))

        state.updateSearchText("")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
    }

    func testClearingSearchRestoresDefaultExpandedGroup() {
        var state = ComposerModelPickerSectionExpansionState()
        state.updateSearchText("gpt")
        state.setExpanded(false, groupID: "openai")

        state.updateSearchText("")

        XCTAssertTrue(state.isExpanded(groupID: "openai", defaultExpandedGroupID: "openai"))
        XCTAssertFalse(state.isExpanded(groupID: "anthropic", defaultExpandedGroupID: "openai"))
    }

    func testChangingSearchQueryReexpandsCollapsedSearchSections() {
        var state = ComposerModelPickerSectionExpansionState()
        state.updateSearchText("gpt")
        state.setExpanded(false, groupID: "openai")
        state.setExpanded(false, groupID: "anthropic")

        XCTAssertFalse(state.isExpanded(groupID: "openai"))
        XCTAssertFalse(state.isExpanded(groupID: "anthropic"))

        state.updateSearchText("gpt 5")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
        XCTAssertTrue(state.isExpanded(groupID: "anthropic"))
    }

    func testGroupExpansionStateIsIndependentAcrossSearchBoundary() {
        var state = ComposerModelPickerSectionExpansionState()
        state.setExpanded(true, groupID: "openai")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
        XCTAssertFalse(state.isExpanded(groupID: "anthropic"))

        state.updateSearchText("claude")
        state.setExpanded(false, groupID: "anthropic")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
        XCTAssertFalse(state.isExpanded(groupID: "anthropic"))

        state.updateSearchText("")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
        XCTAssertFalse(state.isExpanded(groupID: "anthropic"))
    }

    func testWhitespaceOnlySearchUsesEmptySearchState() {
        var state = ComposerModelPickerSectionExpansionState()
        state.setExpanded(true, groupID: "openai")
        state.updateSearchText("gpt")
        state.setExpanded(false, groupID: "openai")

        XCTAssertFalse(state.isExpanded(groupID: "openai"))

        state.updateSearchText("   ")

        XCTAssertTrue(state.isExpanded(groupID: "openai"))
        XCTAssertFalse(state.isExpanded(groupID: "anthropic"))
    }
}

final class ComposerModelPickerShortcutsTests: XCTestCase {
    private let openAI = ModelCatalogOption(
        id: "gpt-5.4",
        displayName: "GPT-5.4",
        providerID: "openai"
    )
    private let claudeOpenRouter = ModelCatalogOption(
        id: "anthropic/claude-sonnet-4",
        displayName: "Claude Sonnet 4",
        providerID: "openrouter"
    )
    private let claudeAnthropic = ModelCatalogOption(
        id: "anthropic/claude-sonnet-4",
        displayName: "Claude Sonnet 4",
        providerID: "anthropic"
    )

    private var groups: [ModelCatalogGroup] {
        [
            ModelCatalogGroup(
                id: "openai",
                name: "OpenAI",
                providerID: "openai",
                models: [openAI]
            ),
            ModelCatalogGroup(
                id: "openrouter",
                name: "OpenRouter",
                providerID: "openrouter",
                models: [claudeOpenRouter]
            ),
            ModelCatalogGroup(
                id: "anthropic",
                name: "Anthropic",
                providerID: "anthropic",
                models: [claudeAnthropic]
            ),
        ]
    }

    func testShortcutAreaDeduplicatesCurrentThenFavoritesThenRecents() {
        let shortcuts = ComposerModelPickerShortcuts.make(
            modelGroups: groups,
            selectedModelID: openAI.id,
            selectedModelProviderID: openAI.providerID,
            favoriteKeys: [openAI.favoriteKey, claudeOpenRouter.favoriteKey],
            recentKeys: [openAI.favoriteKey, claudeOpenRouter.favoriteKey, claudeAnthropic.favoriteKey]
        )

        XCTAssertEqual(shortcuts.current, openAI)
        XCTAssertEqual(shortcuts.favorites, [claudeOpenRouter])
        XCTAssertEqual(shortcuts.recents, [claudeAnthropic])
    }

    func testSameModelIDDifferentProvidersStayDistinct() {
        let shortcuts = ComposerModelPickerShortcuts.make(
            modelGroups: groups,
            selectedModelID: claudeOpenRouter.id,
            selectedModelProviderID: claudeOpenRouter.providerID,
            favoriteKeys: [claudeAnthropic.favoriteKey],
            recentKeys: [claudeOpenRouter.favoriteKey]
        )

        XCTAssertEqual(shortcuts.current, claudeOpenRouter)
        XCTAssertEqual(shortcuts.favorites, [claudeAnthropic])
        XCTAssertTrue(shortcuts.recents.isEmpty)
    }

    func testMissingCatalogSelectionStillAppearsAsCurrent() {
        let shortcuts = ComposerModelPickerShortcuts.make(
            modelGroups: groups,
            selectedModelID: "local-custom",
            selectedModelProviderID: "custom",
            favoriteKeys: [],
            recentKeys: []
        )

        XCTAssertEqual(
            shortcuts.current,
            ModelCatalogOption(id: "local-custom", displayName: "local-custom", providerID: "custom")
        )
        XCTAssertTrue(shortcuts.favorites.isEmpty)
        XCTAssertTrue(shortcuts.recents.isEmpty)
    }

    func testDefaultExpandedGroupIsTheCurrentProvider() {
        let groupID = ComposerModelPickerShortcuts.defaultExpandedGroupID(
            in: groups,
            selectedModelID: claudeAnthropic.id,
            selectedModelProviderID: claudeAnthropic.providerID
        )

        XCTAssertEqual(groupID, "anthropic")
    }

    func testCatalogSearchMatchesDisplayNameIDAndProvider() {
        XCTAssertEqual(
            ComposerModelPickerSheet.catalogGroups(groups, matching: "GPT-5.4").map(\.id),
            ["openai"]
        )
        XCTAssertEqual(
            ComposerModelPickerSheet.catalogGroups(groups, matching: "gpt-5.4").map(\.id),
            ["openai"]
        )
        XCTAssertEqual(
            ComposerModelPickerSheet.catalogGroups(groups, matching: "OpenRouter").map(\.id),
            ["openrouter"]
        )
        XCTAssertEqual(
            ComposerModelPickerSheet.catalogGroups(groups, matching: "anthropic/claude-sonnet-4").map(\.id),
            ["openrouter", "anthropic"]
        )
    }
}
