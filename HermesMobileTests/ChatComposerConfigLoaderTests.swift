import XCTest
import Observation
@testable import HermesMobile


final class ChatComposerConfigLoaderTests: APIClientTestCase {
    func testLoadUsesSessionProfileDefaultAndRefreshesCommands() async throws {
        let openRouterModel = "deepseek/deepseek-chat-v3-0324:free"
        var requestPaths: [String] = []
        let client = makeClient { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true},
                    {"name": "work", "model": "\(openRouterModel)", "provider": "openrouter"}
                  ]
                }
                """, for: request)
            case "/api/profile/switch":
                let body = try apiTestJSONBody(from: request)
                XCTAssertEqual(body["name"] as? String, "work")
                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "default_model": "\(openRouterModel)",
                  "default_workspace": "/tmp/workspace",
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true},
                    {"name": "work", "model": "\(openRouterModel)", "provider": "openrouter", "is_active": true}
                  ]
                }
                """, for: request)
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "default_model": "\(openRouterModel)",
                  "groups": [
                    {
                      "name": "OpenRouter",
                      "provider_id": "openrouter",
                      "models": [
                        {"id": "\(openRouterModel)", "name": "DeepSeek Chat v3 Free"}
                      ]
                    }
                  ]
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces": [{"path": "/tmp/workspace"}], "last": "/tmp/workspace"}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": [{"name": "status", "description": "Show status"}]}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: ChatComposerConfigState(currentProfile: "work")
        )

        XCTAssertNil(result.configurationError)
        XCTAssertEqual(result.state.selectedProfileName, "work")
        XCTAssertEqual(result.state.currentProfile, "work")
        XCTAssertEqual(result.state.currentModel, openRouterModel)
        XCTAssertEqual(result.state.currentModelProvider, "openrouter")
        XCTAssertEqual(result.state.currentWorkspace, "/tmp/workspace")
        XCTAssertEqual(result.state.selectedReasoningEffort, "medium")
        // Older server: no supported_efforts / supports_reasoning_effort fields.
        XCTAssertNil(result.state.supportedReasoningEfforts)
        XCTAssertNil(result.state.supportsReasoningEffort)
        XCTAssertEqual(result.state.workspaceSuggestions, ["/tmp/workspace"])
        XCTAssertEqual(result.state.agentCommands.map(\.name), ["status"])
        XCTAssertTrue(requestPaths.contains("/api/profiles"))
        XCTAssertTrue(requestPaths.contains("/api/profile/switch"))
        XCTAssertTrue(requestPaths.contains("/api/models"))
        XCTAssertTrue(requestPaths.contains("/api/reasoning"))
        XCTAssertTrue(requestPaths.contains("/api/workspaces"))
        XCTAssertTrue(requestPaths.contains("/api/commands"))
        assertProfileResolutionPrecedesCatalogs(requestPaths)
        assertReasoningFollowsResolvedModel(requestPaths)

    }

    func testLoadKeepsSessionModelOverrideWhenProfileHasDifferentDefault() async throws {
        let sessionModel = "@openai:gpt-5.5"
        let profileDefault = "deepseek/deepseek-chat-v3-0324:free"
        var reasoningQueryItems: [String: String?] = [:]
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "profiles": [
                    {"name": "work", "model": "\(profileDefault)", "provider": "openrouter", "is_active": true}
                  ]
                }
                """, for: request)
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "default_model": "\(profileDefault)",
                  "groups": [
                    {
                      "name": "OpenRouter",
                      "provider_id": "openrouter",
                      "models": [{"id": "\(profileDefault)", "name": "DeepSeek Chat v3 Free"}]
                    },
                    {
                      "name": "OpenAI",
                      "provider_id": "openai",
                      "models": [{"id": "\(sessionModel)", "name": "GPT 5.5"}]
                    }
                  ]
                }
                """, for: request)
            case "/api/reasoning":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                reasoningQueryItems = Dictionary(
                    uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) }
                )
                return apiTestJSONResponse("""
                {
                  "reasoning_effort": "high",
                  "supported_efforts": ["low", "medium", "high"],
                  "supports_reasoning_effort": true
                }
                """, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces": [{"path": "/tmp/workspace"}]}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": []}"#, for: request)
            case "/api/default-model":
                XCTFail("Composer configuration loading must not save profile defaults.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: ChatComposerConfigState(
                currentWorkspace: "/tmp/workspace",
                currentModel: sessionModel,
                currentModelProvider: "openai",
                currentProfile: "work"
            )
        )

        XCTAssertNil(result.configurationError)
        XCTAssertEqual(result.state.currentModel, sessionModel)
        XCTAssertEqual(result.state.currentModelProvider, "openai")
        XCTAssertEqual(result.state.selectedProfileName, "work")
        XCTAssertEqual(result.state.selectedReasoningEffort, "high")
        // The reasoning query is scoped to the session's model/provider so the
        // gating fields are model-accurate (issue #18).
        XCTAssertEqual(reasoningQueryItems["model"], sessionModel)
        XCTAssertEqual(reasoningQueryItems["provider"], "openai")
        XCTAssertEqual(result.state.supportedReasoningEfforts, ["low", "medium", "high"])
        XCTAssertEqual(result.state.supportsReasoningEffort, true)
    }

    func testLoadReturnsPartialStateAndStillRefreshesCommandsWhenConfigurationFails() async throws {
        var requestPaths: [String] = []
        let client = makeClient { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true}
                  ]
                }
                """, for: request)
            case "/api/models":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"models unavailable"}"#.utf8))
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces": [{"path": "/tmp/workspace"}], "last": "/tmp/workspace"}"#, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": [{"name": "status"}]}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: ChatComposerConfigState()
        )

        XCTAssertNotNil(result.configurationError)
        XCTAssertEqual(result.state.selectedProfileName, "default")
        XCTAssertEqual(result.state.profileOptions.map(\.name), ["default"])
        XCTAssertEqual(result.state.currentModel, "gpt-5.4")
        XCTAssertEqual(result.state.currentModelProvider, "openai")
        XCTAssertEqual(result.state.currentWorkspace, "/tmp/workspace")
        XCTAssertEqual(result.state.agentCommands.map(\.name), ["status"])
        XCTAssertTrue(requestPaths.contains("/api/profiles"))
        XCTAssertTrue(requestPaths.contains("/api/models"))
        XCTAssertTrue(requestPaths.contains("/api/workspaces"))
        XCTAssertTrue(requestPaths.contains("/api/commands"))
        assertProfileResolutionPrecedesCatalogs(requestPaths)
    }

    func testLoadStoresSingleProfileModeFromProfilesResponse() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true, "is_active": true}
                  ],
                  "single_profile_mode": true
                }
                """, for: request)
            case "/api/models":
                return apiTestJSONResponse(#"{"default_model": "gpt-5.4", "groups": []}"#, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces": [], "last": null}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": []}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: ChatComposerConfigState()
        )

        XCTAssertNil(result.configurationError)
        XCTAssertTrue(result.state.isSingleProfileMode)
    }

    private func assertProfileResolutionPrecedesCatalogs(_ requestPaths: [String]) {
        guard let profilesIndex = requestPaths.firstIndex(of: "/api/profiles") else {
            return XCTFail("Expected /api/profiles")
        }

        let catalogStart = requestPaths.firstIndex(of: "/api/profile/switch") ?? profilesIndex
        for path in ["/api/models", "/api/workspaces", "/api/commands", "/api/reasoning"] {
            guard let index = requestPaths.firstIndex(of: path) else { continue }
            XCTAssertGreaterThan(index, catalogStart, "\(path) must follow profile resolution")
        }
    }

    private func assertReasoningFollowsResolvedModel(_ requestPaths: [String]) {
        guard let reasoningIndex = requestPaths.firstIndex(of: "/api/reasoning") else {
            return XCTFail("Expected /api/reasoning")
        }

        let switchIndex = requestPaths.firstIndex(of: "/api/profile/switch")
        let modelsIndex = requestPaths.firstIndex(of: "/api/models")
        let resolvedBeforeReasoning = (switchIndex.map { $0 < reasoningIndex } ?? false)
            || (modelsIndex.map { $0 < reasoningIndex } ?? false)
        XCTAssertTrue(
            resolvedBeforeReasoning,
            "Reasoning must follow a resolved model/provider"
        )
    }
}


/// Pure gating logic for the composer reasoning-effort menu (issue #18):
/// building the option list from `supported_efforts` and deciding whether
/// the control is shown at all.
final class ReasoningEffortGatingTests: XCTestCase {
    func testOptionsFallBackToStaticListWithoutServerVocabulary() {
        XCTAssertEqual(
            ReasoningEffortOption.options(forSupportedEfforts: nil).map(\.id),
            ["none", "minimal", "low", "medium", "high", "xhigh"]
        )
        // Defensive: an empty list also falls back (the control is hidden
        // before this is rendered because supports_reasoning_effort is false).
        XCTAssertEqual(
            ReasoningEffortOption.options(forSupportedEfforts: []).map(\.id),
            ["none", "minimal", "low", "medium", "high", "xhigh"]
        )
    }

    func testOptionsFilterToServerVocabularyPreservingServerOrder() {
        let options = ReasoningEffortOption.options(forSupportedEfforts: ["high", "low"])
        XCTAssertEqual(options.map(\.id), ["high", "low"])
        XCTAssertEqual(options.map(\.title), ["High", "Low"])
    }

    func testOptionsNormalizeAndKeepUnknownServerEfforts() {
        let options = ReasoningEffortOption.options(forSupportedEfforts: [" Low ", "low", "", "turbo"])
        XCTAssertEqual(options.map(\.id), ["low", "turbo"])
        XCTAssertEqual(options.map(\.title), ["Low", "Turbo"])
    }

    func testShowsEffortControlFollowsServerFlag() {
        XCTAssertFalse(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: false,
            supportedEfforts: ["low"]
        ))
        XCTAssertTrue(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: true,
            supportedEfforts: []
        ))
    }

    func testShowsEffortControlInfersFromEffortsWhenFlagMissing() {
        XCTAssertFalse(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: nil,
            supportedEfforts: []
        ))
        XCTAssertTrue(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: nil,
            supportedEfforts: ["low"]
        ))
        // Older servers send neither field: keep today's behavior (visible).
        XCTAssertTrue(ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: nil,
            supportedEfforts: nil
        ))
    }
}

extension ChatComposerConfigLoaderTests {
    @MainActor
    func testReviewLateCommandsPreserveCompletedWorkspaceSearch() async throws {
        let catalogsStarted = expectation(description: "all independent catalogs started")
        catalogsStarted.expectedFulfillmentCount = 3
        let workspacePublished = expectation(description: "workspace branch published")
        let modelsPublished = expectation(description: "models branch published")
        let requests = ReviewComposerRequests()
        let client = makeReviewClient(requests: requests, started: catalogsStarted)
        defer { ReviewComposerURLProtocol.onRequest = nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id":"review-session"}"#.utf8)
        )
        let viewModel = ChatViewModel(
            session: session,
            server: URL(string: "https://example.test")!,
            client: client,
            workspaceRecentsStore: WorkspaceRecentsStore(keychain: InMemoryKeychainStore()),
            modelRecentsStore: ModelRecentsStore(
                defaults: UserDefaults(suiteName: "review.recents.\(UUID().uuidString)") ?? .standard
            )
        )
        let load = Task { await viewModel.loadComposerConfiguration() }
        await fulfillment(of: [catalogsStarted], timeout: 3)

        withObservationTracking {
            _ = viewModel.workspaceRoots
        } onChange: {
            workspacePublished.fulfill()
        }
        try requests.get("/api/workspaces").complete(json: #"{"workspaces":[{"path":"/work"}]}"#)
        await fulfillment(of: [workspacePublished], timeout: 3)
        XCTAssertEqual(viewModel.workspaceSuggestions, ["/work"])

        withObservationTracking {
            _ = viewModel.modelCatalogGroups
        } onChange: {
            modelsPublished.fulfill()
        }
        try requests.get("/api/models").complete(json: #"{"groups":[{"name":"OpenAI","provider_id":"openai","models":[{"id":"test-model","name":"Test Model"}]}]}"#)
        await fulfillment(of: [modelsPublished], timeout: 3)
        XCTAssertFalse(viewModel.modelCatalogGroups.isEmpty)

        await viewModel.loadWorkspaceSuggestions(prefix: "/work/new")
        XCTAssertEqual(viewModel.workspaceSuggestions, ["/work/new-query-result"])
        XCTAssertTrue(viewModel.isLoadingComposerConfiguration)
        try requests.get("/api/commands").complete(json: #"{"commands":[{"name":"status"}]}"#)
        await load.value
        XCTAssertEqual(
            viewModel.workspaceSuggestions,
            ["/work/new-query-result"],
            "Late commands must not republish the old registry over completed search results"
        )
    }

    @MainActor
    func testReviewLateCommandsPreserveCompletedLiveModelRefresh() async throws {
        let catalogsStarted = expectation(description: "all independent catalogs started")
        catalogsStarted.expectedFulfillmentCount = 3
        let workspacePublished = expectation(description: "workspace branch published")
        let modelsPublished = expectation(description: "models branch published")
        let requests = ReviewComposerRequests()
        let client = makeReviewClient(requests: requests, started: catalogsStarted)
        defer { ReviewComposerURLProtocol.onRequest = nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id":"review-session"}"#.utf8)
        )
        let viewModel = ChatViewModel(
            session: session,
            server: URL(string: "https://example.test")!,
            client: client,
            workspaceRecentsStore: WorkspaceRecentsStore(keychain: InMemoryKeychainStore()),
            modelRecentsStore: ModelRecentsStore(
                defaults: UserDefaults(suiteName: "review.recents.\(UUID().uuidString)") ?? .standard
            )
        )
        let load = Task { await viewModel.loadComposerConfiguration() }
        await fulfillment(of: [catalogsStarted], timeout: 3)

        withObservationTracking {
            _ = viewModel.workspaceRoots
        } onChange: {
            workspacePublished.fulfill()
        }
        try requests.get("/api/workspaces").complete(json: #"{"workspaces":[{"path":"/work"}]}"#)
        await fulfillment(of: [workspacePublished], timeout: 3)
        XCTAssertEqual(viewModel.workspaceSuggestions, ["/work"])

        withObservationTracking {
            _ = viewModel.modelCatalogGroups
        } onChange: {
            modelsPublished.fulfill()
        }
        try requests.get("/api/models").complete(json: #"{"groups":[{"name":"OpenAI","provider_id":"openai","models":[{"id":"test-model","name":"Test Model"}]}]}"#)
        await fulfillment(of: [modelsPublished], timeout: 3)
        XCTAssertFalse(viewModel.modelCatalogGroups.isEmpty)

        ReviewComposerURLProtocol.onRequest = { request in
            switch request.request.url?.path {
            case "/api/models":
                request.complete(json: #"{"groups":[{"name":"OpenAI","provider_id":"openai","models":[{"id":"test-model","name":"Test Model"}]}]}"#)
            case "/api/models/live":
                request.complete(json: #"{"provider":"openai","models":[{"id":"live-only-model","label":"Live Model"}],"count":1}"#)
            default:
                XCTFail("Unexpected refresh request: \(request.request.url?.path ?? "nil")")
                request.complete(status: 500, json: "{}")
            }
        }
        await viewModel.refreshModelCatalogForPickerOpen()
        XCTAssertEqual(viewModel.modelCatalogGroups.flatMap(\.allModels).map(\.id), ["live-only-model"])
        XCTAssertTrue(viewModel.isLoadingComposerConfiguration)
        try requests.get("/api/commands").complete(json: #"{"commands":[{"name":"status"}]}"#)
        await load.value
        XCTAssertEqual(
            viewModel.modelCatalogGroups.flatMap(\.allModels).map(\.id),
            ["live-only-model"],
            "Late commands must not replace a completed live picker refresh with the initial catalog"
        )

        ReviewComposerURLProtocol.onRequest = { request in
            if request.request.url?.path == "/api/models" {
                request.complete(json: #"{"groups":[{"name":"OpenAI","provider_id":"openai","models":[{"id":"second-refresh-model","name":"Second Model"}]}]}"#)
            } else {
                request.complete(status: 500, json: "{}")
            }
        }
        await viewModel.refreshModelCatalogForPickerOpen()
        XCTAssertEqual(viewModel.modelCatalogGroups.flatMap(\.allModels).map(\.id), ["second-refresh-model"])
        ReviewComposerURLProtocol.onRequest = { request in
            request.complete(status: 500, json: "{}")
        }
        await viewModel.refreshModelCatalogForPickerOpen()
        XCTAssertEqual(
            viewModel.modelCatalogGroups.flatMap(\.allModels).map(\.id),
            ["second-refresh-model"],
            "A failed subsequent refresh must retain the last successful catalog"
        )
    }

    @MainActor
    func testReviewFailedPickerCatalogDoesNotBlockPendingInitialCatalog() async throws {
        let catalogsStarted = expectation(description: "all independent catalogs started")
        catalogsStarted.expectedFulfillmentCount = 3
        let requests = ReviewComposerRequests()
        let client = makeReviewClient(requests: requests, started: catalogsStarted)
        defer { ReviewComposerURLProtocol.onRequest = nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id":"review-session"}"#.utf8)
        )
        let viewModel = ChatViewModel(
            session: session,
            server: URL(string: "https://example.test")!,
            client: client,
            workspaceRecentsStore: WorkspaceRecentsStore(keychain: InMemoryKeychainStore()),
            modelRecentsStore: ModelRecentsStore(
                defaults: UserDefaults(suiteName: "review.recents.\(UUID().uuidString)") ?? .standard
            )
        )
        let load = Task { await viewModel.loadComposerConfiguration() }
        await fulfillment(of: [catalogsStarted], timeout: 3)

        ReviewComposerURLProtocol.onRequest = { request in
            if request.request.url?.path == "/api/models/live" {
                request.complete(json: #"{"provider":"openai","models":[{"id":"live-only-model","label":"Live Model"}],"count":1}"#)
            } else {
                request.complete(status: 500, json: "{}")
            }
        }
        await viewModel.refreshModelCatalogForPickerOpen()
        XCTAssertTrue(viewModel.modelCatalogGroups.isEmpty)
        try requests.get("/api/models").complete(json: #"{"groups":[{"name":"OpenAI","provider_id":"openai","models":[{"id":"initial-model","name":"Initial Model"}]}]}"#)
        try requests.get("/api/workspaces").complete(json: #"{"workspaces":[]}"#)
        try requests.get("/api/commands").complete(json: #"{"commands":[]}"#)
        await load.value
        XCTAssertEqual(
            viewModel.modelCatalogGroups.flatMap(\.allModels).map(\.id),
            ["initial-model"],
            "A live response that applied nothing must not suppress the pending initial catalog"
        )
    }


    func testReviewAuthenticationFailureSurvivesEarlierCatalogFailure() async throws {
        let catalogsStarted = expectation(description: "all independent catalogs started")
        catalogsStarted.expectedFulfillmentCount = 3
        let modelFailureApplied = expectation(description: "model failure applied before 401")
        let requests = ReviewComposerRequests()
        let client = makeReviewClient(requests: requests, started: catalogsStarted)
        defer { ReviewComposerURLProtocol.onRequest = nil }
        let projection = ReviewComposerProjection()
        let load = Task {
            await ChatComposerConfigLoader(client: client).loadConfiguration(from: .init()) { state in
                if await projection.apply(state) == 2 { modelFailureApplied.fulfill() }
                return true
            }
        }
        await fulfillment(of: [catalogsStarted], timeout: 3)
        try requests.get("/api/models").complete(status: 500, json: #"{"error":"unavailable"}"#)
        await fulfillment(of: [modelFailureApplied], timeout: 3)
        try requests.get("/api/workspaces").complete(status: 401, json: #"{"error":"unauthorized"}"#)
        try requests.get("/api/commands").complete(json: #"{"commands":[]}"#)
        let result = await load.value
        guard let error = result.configurationError as? APIError,
              case .unauthorized = error else {
            return XCTFail("Expected unauthorized to reach the login-expiry handler; got \(String(describing: result.configurationError))")
        }
    }

    private func makeReviewClient(
        requests: ReviewComposerRequests,
        started: XCTestExpectation
    ) -> APIClient {
        ReviewComposerURLProtocol.onRequest = { request in
            if request.request.url?.path == "/api/profiles" {
                request.complete(json: #"{"active":"default","profiles":[{"name":"default"}]}"#)
            } else if request.request.url?.path == "/api/workspaces/suggest" {
                request.complete(json: #"{"suggestions":["/work/new-query-result"]}"#)
            } else {
                requests.append(request)
                started.fulfill()
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewComposerURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: configuration)
        )
    }
}

private actor ReviewComposerProjection {
    private var count = 0
    func apply(_ state: ChatComposerConfigState) -> Int {
        count += 1
        return count
    }
}

private final class ReviewComposerRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String: ReviewComposerURLProtocol] = [:]

    func append(_ request: ReviewComposerURLProtocol) {
        lock.lock()
        defer { lock.unlock() }
        requests[request.request.url!.path] = request
    }

    func get(_ path: String) throws -> ReviewComposerURLProtocol {
        lock.lock()
        defer { lock.unlock() }
        return try XCTUnwrap(requests[path], "Missing request: \(path)")
    }
}

private final class ReviewComposerURLProtocol: URLProtocol {
    static var onRequest: ((ReviewComposerURLProtocol) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onRequest?(self) }
    override func stopLoading() {}

    func complete(status: Int = 200, json: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension ChatComposerConfigLoaderTests {
    @MainActor
    func testReviewIdenticalApplicableLiveResponseStillProtectsCurrentCatalog() async throws {
        let catalogsStarted = expectation(description: "independent catalogs are pending")
        catalogsStarted.expectedFulfillmentCount = 3
        let requests = ReviewComposerRequests()
        let client = makeReviewClient(requests: requests, started: catalogsStarted)
        let deferredHandler = ReviewComposerURLProtocol.onRequest
        defer { ReviewComposerURLProtocol.onRequest = nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(SessionSummary.self, from: Data(#"{"session_id":"review-session"}"#.utf8))
        let viewModel = ChatViewModel(
            session: session,
            server: URL(string: "https://example.test")!,
            client: client,
            workspaceRecentsStore: WorkspaceRecentsStore(keychain: InMemoryKeychainStore()),
            modelRecentsStore: ModelRecentsStore(
                defaults: UserDefaults(suiteName: "review.recents.\(UUID().uuidString)") ?? .standard
            )
        )

        ReviewComposerURLProtocol.onRequest = { request in
            if request.request.url?.path == "/api/models" {
                request.complete(json: #"{"groups":[{"name":"OpenAI","provider_id":"openai","models":[{"id":"catalog-c","name":"Catalog C"}]}]}"#)
            } else {
                request.complete(json: #"{"provider":"openai","models":[{"id":"catalog-c","label":"Catalog C"}],"count":1}"#)
            }
        }
        await viewModel.refreshModelCatalogForPickerOpen()
        let confirmedCatalog = viewModel.modelCatalogGroups
        XCTAssertEqual(confirmedCatalog.flatMap(\.allModels).map(\.id), ["catalog-c"])

        ReviewComposerURLProtocol.onRequest = deferredHandler
        let load = Task { await viewModel.loadComposerConfiguration() }
        await fulfillment(of: [catalogsStarted], timeout: 3)

        ReviewComposerURLProtocol.onRequest = { request in
            if request.request.url?.path == "/api/models/live" {
                request.complete(json: #"{"provider":"openai","models":[{"id":"catalog-c","label":"Catalog C"}],"count":1}"#)
            } else {
                request.complete(status: 500, json: "{}")
            }
        }
        await viewModel.refreshModelCatalogForPickerOpen()
        XCTAssertEqual(viewModel.modelCatalogGroups, confirmedCatalog)

        try requests.get("/api/models").complete(json: #"{"groups":[{"name":"OpenAI","provider_id":"openai","models":[{"id":"catalog-a","name":"Catalog A"}]}]}"#)
        try requests.get("/api/workspaces").complete(json: #"{"workspaces":[]}"#)
        try requests.get("/api/commands").complete(json: #"{"commands":[]}"#)
        await load.value
        XCTAssertEqual(
            viewModel.modelCatalogGroups,
            confirmedCatalog,
            "An applicable identical live response must protect C from older catalog A"
        )
    }
}


