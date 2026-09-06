import Foundation

struct ChatComposerConfigState: Equatable, Sendable {
    var currentWorkspace: String?
    var currentModel: String?
    var currentModelProvider: String?
    var currentProfile: String?
    var selectedProfileName: String?
    var selectedReasoningEffort: String?
    /// Model-aware effort vocabulary (`supported_efforts`); `nil` on older
    /// servers → composer falls back to the full static list (issue #18).
    var supportedReasoningEfforts: [String]?
    /// `supports_reasoning_effort`; `false` hides the effort control, `nil`
    /// (older servers) keeps it visible.
    var supportsReasoningEffort: Bool?
    var supportsThinkingToggle: Bool?
    var modelCatalogGroups: [ModelCatalogGroup]
    var agentCommands: [AgentCommand]
    var workspaceRoots: [WorkspaceRoot]
    var workspaceSuggestions: [String]
    var profileOptions: [ProfileSummary]
    var isSingleProfileMode: Bool

    init(
        currentWorkspace: String? = nil,
        currentModel: String? = nil,
        currentModelProvider: String? = nil,
        currentProfile: String? = nil,
        selectedProfileName: String? = nil,
        selectedReasoningEffort: String? = nil,
        supportedReasoningEfforts: [String]? = nil,
        supportsReasoningEffort: Bool? = nil,
        supportsThinkingToggle: Bool? = nil,
        modelCatalogGroups: [ModelCatalogGroup] = [],
        agentCommands: [AgentCommand] = [],
        workspaceRoots: [WorkspaceRoot] = [],
        workspaceSuggestions: [String] = [],
        profileOptions: [ProfileSummary] = [],
        isSingleProfileMode: Bool = false
    ) {
        self.currentWorkspace = currentWorkspace
        self.currentModel = currentModel
        self.currentModelProvider = currentModelProvider
        self.currentProfile = currentProfile
        self.selectedProfileName = selectedProfileName
        self.selectedReasoningEffort = selectedReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsThinkingToggle = supportsThinkingToggle
        self.modelCatalogGroups = modelCatalogGroups
        self.agentCommands = agentCommands
        self.workspaceRoots = workspaceRoots
        self.workspaceSuggestions = workspaceSuggestions
        self.profileOptions = profileOptions
        self.isSingleProfileMode = isSingleProfileMode
    }
}

struct ChatComposerConfigLoadResult: Sendable {
    let state: ChatComposerConfigState
    let configurationError: Error?
}

struct ChatComposerConfigLoader {
    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func loadConfiguration(
        from initialState: ChatComposerConfigState,
        onProgress: (@Sendable (ChatComposerConfigState) async -> Bool)? = nil
    ) async -> ChatComposerConfigLoadResult {
        var state = initialState
        var configurationError: Error?

        @discardableResult
        func publish() async -> Bool {
            guard let onProgress else { return true }
            return await onProgress(state)
        }

        do {
            try await resolveProfile(into: &state)
        } catch {
            configurationError = error
            _ = await publish()
            return ChatComposerConfigLoadResult(state: state, configurationError: configurationError)
        }

        guard await publish() else {
            return ChatComposerConfigLoadResult(state: state, configurationError: nil)
        }

        let modelKnown = Self.nonEmpty(state.currentModel) != nil
        let providerKnown = Self.nonEmpty(state.currentModelProvider) != nil
        var didLoadReasoning = false
        var didLoadModels = false

        await withTaskGroup(of: CatalogBranch.self) { group in
            group.addTask { await self.loadModelsBranch() }
            group.addTask { await self.loadWorkspacesBranch() }
            group.addTask { await self.loadCommandsBranch() }
            if modelKnown, providerKnown {
                let model = state.currentModel
                let provider = state.currentModelProvider
                group.addTask { await self.loadReasoningBranch(model: model, provider: provider) }
                didLoadReasoning = true
            }

            for await branch in group {
                apply(branch, to: &state, configurationError: &configurationError)
                if case .models = branch {
                    didLoadModels = true
                    if !didLoadReasoning, Self.nonEmpty(state.currentModel) != nil {
                        didLoadReasoning = true
                        let model = state.currentModel
                        let provider = state.currentModelProvider
                        group.addTask { await self.loadReasoningBranch(model: model, provider: provider) }
                    }
                }
                if await publish() == false {
                    group.cancelAll()
                    break
                }
            }
        }


        if !didLoadReasoning, Self.nonEmpty(state.currentModel) != nil {
            let branch = await loadReasoningBranch(
                model: state.currentModel,
                provider: state.currentModelProvider
            )
            apply(branch, to: &state, configurationError: &configurationError)
            _ = await publish()
        }

        if !didLoadModels, configurationError == nil, Self.nonEmpty(state.currentModelProvider) == nil {
            state.currentModelProvider = Self.uniqueProvider(
                for: state.currentModel,
                in: state.modelCatalogGroups
            )
        }

        return ChatComposerConfigLoadResult(
            state: state,
            configurationError: configurationError
        )
    }

    private func resolveProfile(into state: inout ChatComposerConfigState) async throws {
        let profilesResponse = try await client.profiles()
        state.profileOptions = profilesResponse.profiles ?? []
        state.isSingleProfileMode = profilesResponse.singleProfileMode ?? false
        state.selectedProfileName = Self.nonEmpty(state.currentProfile)
            ?? Self.nonEmpty(profilesResponse.active)
            ?? profilesResponse.effectiveDefaultProfileName

        if let sessionProfile = Self.nonEmpty(state.currentProfile),
           Self.nonEmpty(profilesResponse.active) != sessionProfile {
            let switchResponse = try await client.switchProfile(name: sessionProfile)
            state.profileOptions = switchResponse.profiles ?? state.profileOptions
            state.selectedProfileName = Self.nonEmpty(switchResponse.active) ?? sessionProfile
            state.currentProfile = state.selectedProfileName

            if state.currentWorkspace == nil {
                state.currentWorkspace = Self.nonEmpty(switchResponse.defaultWorkspace)
            }

            if state.currentModel == nil {
                state.currentModel = Self.nonEmpty(switchResponse.defaultModel)
            }
        }

        let selectedProfile = Self.profileSummary(
            matching: state.selectedProfileName,
            in: state.profileOptions
        )
        if state.currentModel == nil {
            state.currentModel = Self.nonEmpty(selectedProfile?.model)
        }
        if Self.nonEmpty(state.currentModelProvider) == nil {
            state.currentModelProvider = Self.nonEmpty(selectedProfile?.provider)
        }
    }

    private enum CatalogBranch: @unchecked Sendable {
        case models(ModelsResponse)
        case workspaces(WorkspacesResponse)
        case commands([AgentCommand])
        case reasoning(ReasoningStatusResponse)
        case failed(Error)
        case commandsFailed
    }


    private func loadModelsBranch() async -> CatalogBranch {
        do {
            return .models(try await client.models())
        } catch {
            return .failed(error)
        }
    }

    private func loadWorkspacesBranch() async -> CatalogBranch {
        do {
            return .workspaces(try await client.workspaces())
        } catch {
            return .failed(error)
        }
    }

    private func loadCommandsBranch() async -> CatalogBranch {
        do {
            return .commands((try await client.commands()).commands ?? [])
        } catch {
            return .commandsFailed
        }
    }

    private func loadReasoningBranch(model: String?, provider: String?) async -> CatalogBranch {
        do {
            return .reasoning(
                try await client.reasoning(
                    model: Self.nonEmpty(model),
                    provider: Self.nonEmpty(provider)
                )
            )
        } catch {
            return .failed(error)
        }
    }

    private func apply(
        _ branch: CatalogBranch,
        to state: inout ChatComposerConfigState,
        configurationError: inout Error?
    ) {
        switch branch {
        case let .models(response):
            state.modelCatalogGroups = response.catalogGroups
            if state.currentModel == nil {
                state.currentModel = response.defaultModel
            }
            if Self.nonEmpty(state.currentModelProvider) == nil {
                state.currentModelProvider = Self.uniqueProvider(
                    for: state.currentModel,
                    in: state.modelCatalogGroups
                )
            }
        case let .workspaces(response):
            state.workspaceRoots = response.workspaces ?? []
            if state.currentWorkspace == nil {
                state.currentWorkspace = response.last ?? state.workspaceRoots.compactMap(\.path).first
            }
            state.workspaceSuggestions = state.workspaceRoots.compactMap(\.path)
        case let .commands(commands):
            state.agentCommands = commands
        case let .reasoning(response):
            state.selectedReasoningEffort = response.effectiveEffort
            state.supportedReasoningEfforts = response.normalizedSupportedEfforts
            state.supportsReasoningEffort = response.supportsReasoningEffort
            state.supportsThinkingToggle = response.supportsThinkingToggle
        case let .failed(error):
            configurationError = Self.preferringAuthenticationFailure(
                existing: configurationError,
                incoming: error
            )
        case .commandsFailed:
            state.agentCommands = []
        }
    }

    private static func preferringAuthenticationFailure(existing: Error?, incoming: Error) -> Error {
        if case APIError.unauthorized = incoming {
            return incoming
        }
        if let existing, case APIError.unauthorized = existing {
            return existing
        }
        return existing ?? incoming
    }

    private static func profileSummary(
        matching profileName: String?,
        in profileOptions: [ProfileSummary]
    ) -> ProfileSummary? {
        guard let profileName = nonEmpty(profileName) else { return nil }
        return profileOptions.first { $0.normalizedName == profileName }
    }

    private static func uniqueProvider(
        for modelID: String?,
        in groups: [ModelCatalogGroup]
    ) -> String? {
        guard let modelID = nonEmpty(modelID) else { return nil }
        let providers = Set(
            groups
                .flatMap(\.allModels)
                .filter { $0.id == modelID }
                .compactMap { nonEmpty($0.providerID) }
        )
        return providers.count == 1 ? providers.first : nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
