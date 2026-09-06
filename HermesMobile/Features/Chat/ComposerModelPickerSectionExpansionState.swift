import Foundation

struct ComposerModelPickerSectionExpansionState {
    private var expandedGroupIDs: Set<String> = []
    private var collapsedBrowseGroupIDs: Set<String> = []
    private var collapsedSearchGroupIDs: Set<String> = []
    private var searchQuery = ""

    mutating func updateSearchText(_ searchText: String) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != searchQuery else { return }

        searchQuery = query
        collapsedSearchGroupIDs.removeAll()
    }

    func isExpanded(groupID: String, defaultExpandedGroupID: String? = nil) -> Bool {
        if searchQuery.isEmpty {
            if collapsedBrowseGroupIDs.contains(groupID) {
                return false
            }
            if expandedGroupIDs.contains(groupID) {
                return true
            }
            return groupID == defaultExpandedGroupID
        }

        return !collapsedSearchGroupIDs.contains(groupID)
    }

    mutating func setExpanded(_ isExpanded: Bool, groupID: String) {
        if searchQuery.isEmpty {
            if isExpanded {
                expandedGroupIDs.insert(groupID)
                collapsedBrowseGroupIDs.remove(groupID)
            } else {
                expandedGroupIDs.remove(groupID)
                collapsedBrowseGroupIDs.insert(groupID)
            }
        } else if isExpanded {
            collapsedSearchGroupIDs.remove(groupID)
        } else {
            collapsedSearchGroupIDs.insert(groupID)
        }
    }
}

/// Tracks the provider groups whose server-supplied overflow models the user
/// has chosen to reveal. Both model pickers use the same small state model so
/// their counts and visible rows cannot drift apart.
struct ModelPickerOverflowExpansionState {
    private var expandedGroupIDs: Set<String> = []

    func isExpanded(groupID: String) -> Bool {
        expandedGroupIDs.contains(groupID)
    }

    func displayedModels(in group: ModelCatalogGroup) -> [ModelCatalogOption] {
        isExpanded(groupID: group.id) ? group.allModels : group.models
    }

    mutating func setExpanded(_ isExpanded: Bool, groupID: String) {
        if isExpanded {
            expandedGroupIDs.insert(groupID)
        } else {
            expandedGroupIDs.remove(groupID)
        }
    }
}

/// Current, favorites, and recents for the composer model picker shortcut area.
/// Identity is model ID + provider; the same combination appears at most once,
/// in current → favorites → recents order.
struct ComposerModelPickerShortcuts: Equatable {
    var current: ModelCatalogOption?
    var favorites: [ModelCatalogOption]
    var recents: [ModelCatalogOption]

    var isEmpty: Bool {
        current == nil && favorites.isEmpty && recents.isEmpty
    }

    static func make(
        modelGroups: [ModelCatalogGroup],
        selectedModelID: String?,
        selectedModelProviderID: String?,
        favoriteKeys: [ModelFavoriteKey],
        recentKeys: [ModelFavoriteKey]
    ) -> Self {
        let current = resolvedSelection(
            in: modelGroups.flatMap(\.allModels),
            selectedModelID: selectedModelID,
            selectedModelProviderID: selectedModelProviderID
        )
        let currentKey = current?.favoriteKey

        let favorites = ModelFavoritesStore.visibleFavoriteOptions(
            in: modelGroups,
            favoriteKeys: favoriteKeys
        ).filter { $0.favoriteKey != currentKey }

        let recents = ModelRecentsStore.visibleRecentOptions(
            in: modelGroups,
            recentKeys: recentKeys,
            favoriteKeys: favoriteKeys
        ).filter { $0.favoriteKey != currentKey }

        return Self(current: current, favorites: favorites, recents: recents)
    }

    static func resolvedSelection(
        in options: [ModelCatalogOption],
        selectedModelID: String?,
        selectedModelProviderID: String?
    ) -> ModelCatalogOption? {
        guard let selectedModelID, !selectedModelID.isEmpty else { return nil }

        return options.firstMatchingSelection(
            modelID: selectedModelID,
            providerID: selectedModelProviderID
        ) ?? ModelCatalogOption(
            id: selectedModelID,
            displayName: selectedModelID,
            providerID: selectedModelProviderID
        )
    }

    static func defaultExpandedGroupID(
        in groups: [ModelCatalogGroup],
        selectedModelID: String?,
        selectedModelProviderID: String?
    ) -> String? {
        groups.first { group in
            group.allModels.contains {
                $0.matchesSelection(
                    modelID: selectedModelID,
                    providerID: selectedModelProviderID
                )
            }
        }?.id
    }
}
