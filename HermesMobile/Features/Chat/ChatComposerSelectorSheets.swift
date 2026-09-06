import SwiftUI

struct ComposerModelPickerSheet: View {
    let modelGroups: [ModelCatalogGroup]
    let selectedModelID: String?
    let selectedModelProviderID: String?
    let favoriteModelKeys: [ModelFavoriteKey]
    let recentModelKeys: [ModelFavoriteKey]
    let onSelect: (ModelCatalogOption) -> Void
    let onToggleFavorite: (ModelCatalogOption) -> Void
    let onDeleteSavedCustom: (ModelCatalogOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var customModelID = ""
    @State private var customProviderID = ""
    @State private var sectionExpansion = ComposerModelPickerSectionExpansionState()
    @State private var overflowExpansion = ModelPickerOverflowExpansionState()
    @State private var showsCustomModelEntry = false


    private let currentCustomGroupID = "current-custom-model"
    private let savedCustomGroupID = "saved-custom-models"

    var body: some View {
        NavigationStack {
            List {
                if searchQuery.isEmpty {
                    shortcutSections
                }

                ForEach(filteredModelGroups) { group in
                    modelGroupDisclosure(group)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                if filteredModelGroups.isEmpty && !searchQuery.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .listRowSeparator(.hidden)
                }

                advancedCustomModelEntry
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Choose Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search models"
            )
            .onAppear {
                initializeCustomProviderIfNeeded()
                sectionExpansion.updateSearchText(searchText)
            }
            .onChange(of: searchText) { _, newValue in
                sectionExpansion.updateSearchText(newValue)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .adaptiveFormPresentation()
    }

    @ViewBuilder
    private var shortcutSections: some View {
        if let current = shortcuts.current {
            Section("Current") {
                modelOptionRow(current, allowsDelete: false)
            }
        }

        if !shortcuts.favorites.isEmpty {
            Section("Favorites") {
                ForEach(shortcuts.favorites, id: \.self) { option in
                    modelOptionRow(option, allowsDelete: false)
                }
            }
        }

        if !shortcuts.recents.isEmpty {
            Section("Recent") {
                ForEach(shortcuts.recents, id: \.self) { option in
                    modelOptionRow(option, allowsDelete: false)
                }
            }
        }
    }

    private var advancedCustomModelEntry: some View {
        DisclosureGroup(isExpanded: $showsCustomModelEntry) {
            customModelEntry
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Advanced")
                    .font(AppFont.subheadline(weight: .semibold))
                Text("Enter a custom model ID")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
        .tint(Color(.secondaryLabel))
        .accessibilityHint("Shows the custom model form")
    }

    private var customModelEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom Model")
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 7) {
                TextField("Exact model ID", text: $customModelID)
                    .font(AppFont.body())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 8) {
                    TextField("Provider ID", text: $customProviderID)
                        .font(AppFont.body())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if !providerChoices.isEmpty {
                        Menu {
                            ForEach(providerChoices) { provider in
                                Button(provider.name) {
                                    customProviderID = provider.id
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                                .font(AppFont.title3())
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose provider ID")
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    guard let customOption else { return }
                    onSelect(customOption)
                    dismiss()
                } label: {
                    Label("Use Custom", systemImage: "plus.circle.fill")
                        .font(AppFont.subheadline(weight: .semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(customOption == nil)

                Button {
                    guard let customOption else { return }
                    onToggleFavorite(customOption)
                } label: {
                    Image(systemName: isCustomOptionFavorite ? "star.fill" : "star")
                        .font(AppFont.body())
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isCustomOptionFavorite ? Color.yellow : Color(.tertiaryLabel))
                .disabled(customOption == nil)
                .accessibilityLabel(isCustomOptionFavorite ? "Remove custom model from favorites" : "Add custom model to favorites")

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }


    private func modelGroupDisclosure(_ group: ModelCatalogGroup) -> some View {
        let displayedModels = overflowExpansion.displayedModels(in: group)
        let totalModelCount = group.allModels.count

        return DisclosureGroup(
            isExpanded: Binding(
                get: { sectionExpansion.isExpanded(groupID: group.id, defaultExpandedGroupID: defaultExpandedGroupID) },
                set: { isExpanded in
                    sectionExpansion.setExpanded(isExpanded, groupID: group.id)
                }
            )
        ) {
            VStack(spacing: 1) {
                Divider()
                    .padding(.leading, 10)

                LazyVStack(spacing: 1) {
                    ForEach(displayedModels, id: \.self) { option in
                        modelOptionRow(option, allowsDelete: group.id == savedCustomGroupID)
                    }
                }

                if shouldShowOverflowToggle(for: group) {
                    Divider()
                        .padding(.leading, 10)

                    overflowToggle(for: group)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text(group.name)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(
                    totalModelCount > group.models.count
                        ? "\(displayedModels.count) / \(totalModelCount)"
                        : "\(displayedModels.count)"
                )
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        Text("Showing \(displayedModels.count) of \(totalModelCount) models")
                    )

                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .tint(Color(.secondaryLabel))
    }

    private func shouldShowOverflowToggle(for group: ModelCatalogGroup) -> Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !group.extraModels.isEmpty
    }

    private func overflowToggle(for group: ModelCatalogGroup) -> some View {
        let isExpanded = overflowExpansion.isExpanded(groupID: group.id)

        return Button {
            overflowExpansion.setExpanded(!isExpanded, groupID: group.id)
        } label: {
            HStack(spacing: 8) {
                Text(
                    isExpanded
                        ? String(localized: "Show fewer models")
                        : String(localized: "Show all models")
                )
                    .font(AppFont.subheadline(weight: .semibold))

                Spacer(minLength: 0)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(AppFont.caption(weight: .semibold))
                    .accessibilityHidden(true)
            }
            .padding(.leading, 28)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelOptionRow(_ option: ModelCatalogOption, allowsDelete: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                onSelect(option)
                dismiss()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: isSelected(option) ? "checkmark.circle.fill" : "circle")
                        .font(AppFont.body())
                        .foregroundStyle(isSelected(option) ? Color.accentColor : Color(.tertiaryLabel))
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.displayName)
                            .font(AppFont.body())
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        if option.id != option.displayName {
                            Text(option.id)
                                .font(AppFont.caption())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if let providerID = option.providerID, !providerID.isEmpty {
                            Text(providerID)
                                .font(AppFont.caption())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(modelAccessibilityLabel(option))

            Button {
                onToggleFavorite(option)
            } label: {
                Image(systemName: isFavorite(option) ? "star.fill" : "star")
                    .font(AppFont.body())
                    .foregroundStyle(isFavorite(option) ? Color.yellow : Color(.tertiaryLabel))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite(option) ? "Remove \(option.displayName) from favorites" : "Add \(option.displayName) to favorites")

            if allowsDelete {
                Button {
                    onDeleteSavedCustom(option)
                } label: {
                    Image(systemName: "trash")
                        .font(AppFont.body())
                        .foregroundStyle(Color.red)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete saved custom model \(option.displayName)")
            }
        }
        .padding(.leading, 2)
        .padding(.vertical, 3)
    }

    private func modelAccessibilityLabel(_ option: ModelCatalogOption) -> String {
        var parts = [option.displayName]
        if let providerID = option.providerID, !providerID.isEmpty {
            parts.append(providerID)
        }
        if isSelected(option) {
            parts.append(String(localized: "Selected"))
        }
        return parts.joined(separator: ", ")
    }


    private func isFavorite(_ option: ModelCatalogOption) -> Bool {
        favoriteModelKeys.contains(option.favoriteKey)
    }

    private var isCustomOptionFavorite: Bool {
        customOption.map(isFavorite) ?? false
    }

    private func isSelected(_ option: ModelCatalogOption) -> Bool {
        option.matchesSelection(modelID: selectedModelID, providerID: selectedModelProviderID)
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shortcuts: ComposerModelPickerShortcuts {
        ComposerModelPickerShortcuts.make(
            modelGroups: modelGroups,
            selectedModelID: selectedModelID,
            selectedModelProviderID: selectedModelProviderID,
            favoriteKeys: favoriteModelKeys,
            recentKeys: recentModelKeys
        )
    }

    private var defaultExpandedGroupID: String? {
        ComposerModelPickerShortcuts.defaultExpandedGroupID(
            in: modelGroups,
            selectedModelID: selectedModelID,
            selectedModelProviderID: selectedModelProviderID
        )
    }

    private var filteredModelGroups: [ModelCatalogGroup] {
        let baseGroups = Self.catalogGroups(modelGroups, matching: searchQuery)
        if searchQuery.isEmpty {
            return baseGroups
        }
        return customModelGroups + baseGroups
    }

    static func catalogGroups(
        _ modelGroups: [ModelCatalogGroup],
        matching searchQuery: String
    ) -> [ModelCatalogGroup] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return modelGroups }

        return modelGroups.compactMap { group in
            let groupMatches = group.name.localizedCaseInsensitiveContains(query)
                || (group.providerID?.localizedCaseInsensitiveContains(query) ?? false)
            let filteredModels = groupMatches
                ? group.allModels
                : group.allModels.filter { matches($0, query: query) }
            guard !filteredModels.isEmpty else { return nil }
            return ModelCatalogGroup(
                id: group.id,
                name: group.name,
                providerID: group.providerID,
                models: filteredModels
            )
        }
    }


    private var customModelGroups: [ModelCatalogGroup] {
        var groups: [ModelCatalogGroup] = []

        if let selectedCustomOption,
           !storedCustomOptions.contains(where: { $0.favoriteKey == selectedCustomOption.favoriteKey }) {
            groups.append(
                ModelCatalogGroup(
                    id: currentCustomGroupID,
                    name: String(localized: "Current Custom"),
                    providerID: nil,
                    models: [selectedCustomOption]
                )
            )
        }

        if !storedCustomOptions.isEmpty {
            groups.append(
                ModelCatalogGroup(
                    id: savedCustomGroupID,
                    name: String(localized: "Saved Custom"),
                    providerID: nil,
                    models: storedCustomOptions
                )
            )
        }

        return groups
    }

    private var storedCustomOptions: [ModelCatalogOption] {
        let catalogKeys = Set(modelGroups.flatMap(\.allModels).map(\.favoriteKey))
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<ModelFavoriteKey>()
        var result: [ModelCatalogOption] = []

        func append(_ option: ModelCatalogOption?) {
            guard let option,
                  !catalogKeys.contains(option.favoriteKey),
                  seen.insert(option.favoriteKey).inserted,
                  query.isEmpty || matches(option, query: query) else { return }
            result.append(option)
        }

        for option in ModelFavoritesStore.visibleFavoriteOptions(in: modelGroups, favoriteKeys: favoriteModelKeys) {
            append(option)
        }
        for option in ModelRecentsStore.visibleRecentOptions(
            in: modelGroups,
            recentKeys: recentModelKeys,
            favoriteKeys: favoriteModelKeys
        ) {
            append(option)
        }

        return result
    }

    private var customOption: ModelCatalogOption? {
        let modelID = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerID = customProviderID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !modelID.isEmpty, !providerID.isEmpty else { return nil }
        return ModelCatalogOption(id: modelID, displayName: modelID, providerID: providerID)
    }

    private var selectedCustomOption: ModelCatalogOption? {
        guard let selectedModelID, !selectedModelID.isEmpty else { return nil }
        let option = ModelCatalogOption(
            id: selectedModelID,
            displayName: selectedModelID,
            providerID: selectedModelProviderID
        )
        let isRendered = Self.isRenderedByCurrentPicker(
            option: option,
            modelGroups: modelGroups,
            searchQuery: searchText,
            overflowExpansion: overflowExpansion
        )
        guard !isRendered else { return nil }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty || matches(option, query: query) else { return nil }
        return option
    }

    /// Whether `option` is already represented by a rendered picker row under
    /// the current query. Empty query renders the server's visible slice plus
    /// any provider groups the user expanded; searching renders `allModels`.
    /// Classifying every empty-query group against the full catalog would hide
    /// the "Current Custom" row for an overflow selection that is still hidden.
    static func isRenderedByCurrentPicker(
        option: ModelCatalogOption,
        modelGroups: [ModelCatalogGroup],
        searchQuery: String,
        overflowExpansion: ModelPickerOverflowExpansionState = .init()
    ) -> Bool {
        let renderedOptions: [ModelCatalogOption]
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            renderedOptions = modelGroups.flatMap { overflowExpansion.displayedModels(in: $0) }
        } else {
            renderedOptions = modelGroups.flatMap(\.allModels)
        }
        return renderedOptions.firstMatchingSelection(
            modelID: option.id,
            providerID: option.providerID
        ) != nil
    }

    private var providerChoices: [ModelProviderChoice] {
        var seen = Set<String>()
        var result: [ModelProviderChoice] = []

        for group in modelGroups {
            guard let providerID = group.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !providerID.isEmpty,
                  seen.insert(providerID.lowercased()).inserted else { continue }
            result.append(ModelProviderChoice(id: providerID, name: group.name))
        }

        if let selectedModelProviderID = selectedModelProviderID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedModelProviderID.isEmpty,
           seen.insert(selectedModelProviderID.lowercased()).inserted {
            result.insert(
                ModelProviderChoice(id: selectedModelProviderID, name: selectedModelProviderID),
                at: 0
            )
        }

        return result
    }

    private func initializeCustomProviderIfNeeded() {
        guard customProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        customProviderID = selectedModelProviderID ?? providerChoices.first?.id ?? ""
    }

    private func matches(_ option: ModelCatalogOption, query: String) -> Bool {
        Self.matches(option, query: query)
    }

    static func matches(_ option: ModelCatalogOption, query: String) -> Bool {
        option.displayName.localizedCaseInsensitiveContains(query)
            || option.id.localizedCaseInsensitiveContains(query)
            || (option.providerID?.localizedCaseInsensitiveContains(query) ?? false)
    }
}

private struct ModelProviderChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct ComposerWorkspacePickerSheet: View {
    let workspaceRoots: [WorkspaceRoot]
    let selectedWorkspacePath: String?
    let recentPaths: [String]
    let suggestions: [String]
    var isLoadingSuggestions = false
    var suggestionsErrorMessage: String?
    /// Server base URL used to open the registry manager; nil hides the
    /// Manage affordance (e.g. offline cached mode).
    var managementServer: URL?
    let onLoadSuggestions: (String) async -> Void
    var onRetrySuggestions: () async -> Void = {}
    let onSelect: (String) async -> Void
    /// Called after the registry manager closes having changed the registry,
    /// so the owner can refetch `workspaceRoots`.
    var onRegistryChanged: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var prefix = ""
    @State private var acceptedWorkspacePath: String?
    @State private var showsManagerSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search name or path", text: $prefix)
                        .font(AppFont.body())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                } footer: {
                    Text("Local names and paths filter immediately. Path suggestions stay inside trusted workspace roots.")
                }

                if let current = content.current {
                    Section("Current") {
                        workspaceButton(current)
                    }
                }

                if !content.recents.isEmpty {
                    Section("Recent") {
                        ForEach(content.recents) { row in
                            workspaceButton(row)
                        }
                    }
                }

                if !content.saved.isEmpty {
                    Section("Saved Workspaces") {
                        ForEach(content.saved) { row in
                            workspaceButton(row)
                        }
                    }
                }

                if !content.suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(content.suggestions) { row in
                            workspaceButton(row)
                        }
                    }
                }

                if isLoadingSuggestions {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading path suggestions...")
                                .font(AppFont.subheadline())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                if let suggestionsErrorMessage, !suggestionsErrorMessage.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(suggestionsErrorMessage)
                                .font(AppFont.subheadline())
                                .foregroundStyle(.primary)
                            Button("Retry") {
                                Task {
                                    await onRetrySuggestions()
                                }
                            }
                            .font(AppFont.body())
                            .frame(minHeight: 44)
                        }
                    }
                }

                if shouldShowNoResults {
                    ContentUnavailableView.search(text: prefix)
                } else if content.isEmpty && !isLoadingSuggestions && suggestionsErrorMessage == nil {
                    ContentUnavailableView {
                        Label("No Workspaces", systemImage: "folder")
                    } description: {
                        Text("Try typing a path under your home folder or an existing workspace root.")
                    }
                }
            }
            .navigationTitle("Choose Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if managementServer != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Manage") {
                            showsManagerSheet = true
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task(id: prefix) {
                if !prefix.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                }
                await onLoadSuggestions(prefix)
            }
            .sheet(isPresented: $showsManagerSheet) {
                if let managementServer {
                    WorkspaceManagerView(server: managementServer) {
                        await onRegistryChanged()
                    }
                    .adaptiveFormPresentation()
                }
            }
        }
        .adaptiveFormPresentation()
    }

    private var content: ComposerWorkspacePickerContent {
        ComposerWorkspacePickerContent.make(
            query: prefix,
            currentPath: effectiveSelectedWorkspacePath,
            savedRoots: workspaceRoots,
            recentPaths: recentPaths,
            suggestions: suggestions
        )
    }

    private var shouldShowNoResults: Bool {
        !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && content.isEmpty
            && !isLoadingSuggestions
            && suggestionsErrorMessage == nil
    }

    private func workspaceButton(_ row: ComposerWorkspacePickerRow) -> some View {
        Button {
            guard acceptedWorkspacePath == nil else { return }
            acceptedWorkspacePath = row.path
            dismiss()
            Task {
                await onSelect(row.path)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: row.isCurrent ? "checkmark.circle.fill" : "folder")
                    .font(AppFont.body())
                    .foregroundStyle(row.isCurrent ? Color.accentColor : Color(.secondaryLabel))
                    .frame(minWidth: 44, minHeight: 44, alignment: .top)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.displayName)
                            .font(AppFont.body())
                            .foregroundStyle(.primary)
                        if row.isCurrent {
                            Text("Current")
                                .font(AppFont.caption(weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(row.path)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(acceptedWorkspacePath != nil)
        .accessibilityLabel(workspaceAccessibilityLabel(row))
    }

    private func workspaceAccessibilityLabel(_ row: ComposerWorkspacePickerRow) -> String {
        var parts = [row.displayName, row.path]
        if row.isCurrent {
            parts.append(String(localized: "Current"))
        }
        return parts.joined(separator: ", ")
    }

    private var effectiveSelectedWorkspacePath: String? {
        acceptedWorkspacePath ?? selectedWorkspacePath
    }
}


extension String {
    var lastPathComponentFallback: String {
        let component = (self as NSString).lastPathComponent
        return component.isEmpty ? self : component
    }
}
