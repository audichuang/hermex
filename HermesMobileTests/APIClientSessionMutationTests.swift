import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientSessionMutationTests: APIClientTestCase {
    /// Upstream reads `worktree` by PRESENCE: an absent key means "inherit the
    /// profile's config-level `worktree:` default", so a server configured with
    /// `worktree: true` would silently give every app-created session a git
    /// worktree and swap its workspace for the worktree path. The key must
    /// therefore always be on the wire.
    func testCreateSessionAlwaysStatesWorktreeExplicitly() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/new")

            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(body["worktree"] as? Bool, false)
            XCTAssertTrue(body.keys.contains("worktree"), "An absent key means 'inherit the server default'.")
            // No previous session in this flow, so the key stays off the wire.
            XCTAssertNil(body["prev_session_id"])

            return apiTestJSONResponse("""
            {"session": {"session_id": "new-1", "workspace": "/repo"}}
            """, for: request)
        }

        let response = try await client.createSession(
            workspace: "/repo",
            model: nil,
            modelProvider: nil,
            profile: nil
        )

        XCTAssertEqual(response.session?.sessionId, "new-1")
    }

    /// `prev_session_id` is what lets the server commit the previous session's
    /// memory before the new one starts; omitting it skipped that entirely.
    func testCreateSessionForwardsPreviousSessionIDForMemoryHandoff() async throws {
        let client = makeClient { request in
            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(body["prev_session_id"] as? String, "session-old")
            XCTAssertNil(body["prevSessionId"])
            XCTAssertEqual(body["worktree"] as? Bool, false)

            return apiTestJSONResponse(#"{"session": {"session_id": "new-2"}}"#, for: request)
        }

        let response = try await client.createSession(
            workspace: "/repo",
            model: nil,
            modelProvider: nil,
            profile: nil,
            previousSessionID: "session-old"
        )

        XCTAssertEqual(response.session?.sessionId, "new-2")
    }

    func testCreateSessionCanRequestAWorktreeExplicitly() async throws {
        let client = makeClient { request in
            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(body["worktree"] as? Bool, true)

            return apiTestJSONResponse(#"{"session": {"session_id": "new-3"}}"#, for: request)
        }

        _ = try await client.createSession(
            workspace: "/repo",
            model: nil,
            modelProvider: nil,
            profile: nil,
            worktree: true
        )
    }

    func testPostRequestsEncodeSnakeCaseBody() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/pin")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertEqual(json?["pinned"] as? Bool, false)
            XCTAssertNil(json?["sessionId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "session": {
                "session_id": "abc123",
                "pinned": false
              }
            }
            """, for: request)
        }

        let response = try await client.pinSession(id: "abc123", pinned: false)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.session?.sessionId, "abc123")
        XCTAssertEqual(response.session?.pinned, false)
    }

    func testBranchSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/branch")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertEqual(json?["title"] as? String, "Planning (copy)")
            XCTAssertNil(json?["keep_count"])
            XCTAssertNil(json?["sessionId"])

            return apiTestJSONResponse("""
            {
              "session_id": "copy123",
              "title": "Planning (copy)",
              "parent_session_id": "abc123"
            }
            """, for: request)
        }

        let response = try await client.branchSession(id: "abc123", title: "Planning (copy)")

        XCTAssertEqual(response.sessionId, "copy123")
        XCTAssertEqual(response.title, "Planning (copy)")
        XCTAssertEqual(response.parentSessionId, "abc123")
    }

    func testBranchSessionIncludesKeepCountForMessageFork() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/branch")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertEqual(json?["keep_count"] as? Int, 29)
            XCTAssertNil(json?["title"])
            XCTAssertNil(json?["sessionId"])

            return apiTestJSONResponse("""
            {
              "session_id": "fork123",
              "title": "Planning (fork)",
              "parent_session_id": "abc123"
            }
            """, for: request)
        }

        let response = try await client.branchSession(id: "abc123", keepCount: 29)

        XCTAssertEqual(response.sessionId, "fork123")
        XCTAssertEqual(response.title, "Planning (fork)")
        XCTAssertEqual(response.parentSessionId, "abc123")
    }

    /// Compression goes through the asynchronous job the web client uses. The
    /// synchronous endpoint ran the whole compaction inside one request, so a
    /// long transcript reliably outlived the request timeout while the server
    /// finished anyway and rotated the session id behind the client (#24).
    func testCompressSessionStartsTheAsynchronousJobAndDecodesAnImmediateResult() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/compress/start")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertEqual(json?["focus_topic"] as? String, "architecture notes")
            XCTAssertNil(json?["sessionId"])
            XCTAssertNil(json?["focusTopic"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "status": "done",
              "focus_topic": "architecture notes",
              "summary": {
                "headline": "Compressed: 8 -> 3 messages",
                "token_line": "Rough transcript estimate: ~1200 -> ~320 tokens",
                "reference_message": "[CONTEXT COMPACTION] Compression completed."
              },
              "session": {
                "session_id": "abc123",
                "title": "Planning",
                "messages": []
              }
            }
            """, for: request)
        }

        let response = try await client.compressSession(id: "abc123", focusTopic: "architecture notes")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.focusTopic, "architecture notes")
        XCTAssertEqual(response.summary?.headline, "Compressed: 8 -> 3 messages")
        XCTAssertEqual(response.summary?.tokenLine, "Rough transcript estimate: ~1200 -> ~320 tokens")
        XCTAssertEqual(response.summary?.referenceMessage, "[CONTEXT COMPACTION] Compression completed.")
        XCTAssertEqual(response.session?.sessionId, "abc123")
    }

    /// A `running` start is polled until the job leaves that state, and the
    /// terminal payload carries the rotated session id.
    func testCompressSessionPollsAJobThatIsStillRunning() async throws {
        nonisolated(unsafe) var paths: [String] = []
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            let count = paths.count

            if path == "/api/session/compress/start" {
                return apiTestJSONResponse(#"{"ok": true, "status": "running", "session_id": "abc123"}"#, for: request)
            }

            XCTAssertEqual(path, "/api/session/compress/status")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            XCTAssertEqual(components?.queryItems?.first { $0.name == "session_id" }?.value, "abc123")

            if count == 2 {
                return apiTestJSONResponse(#"{"ok": true, "status": "running", "session_id": "abc123"}"#, for: request)
            }
            return apiTestJSONResponse("""
            {"ok": true, "status": "done",
             "session": {"session_id": "abc123-compressed", "messages": []}}
            """, for: request)
        }

        let response = try await client.compressSession(
            id: "abc123",
            pollInterval: .milliseconds(10),
            timeout: .seconds(5)
        )

        XCTAssertEqual(response.status, "done")
        XCTAssertEqual(response.session?.sessionId, "abc123-compressed")
        XCTAssertEqual(paths.count, 3)
    }

    /// A deployment without the asynchronous routes answers the start with 404;
    /// the synchronous endpoint still has to work there.
    func testCompressSessionFallsBackToTheSynchronousEndpointOn404() async throws {
        nonisolated(unsafe) var paths: [String] = []
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)

            if path == "/api/session/compress/start" {
                return (
                    try XCTUnwrap(HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: nil
                    )),
                    Data(#"{"error": "not found"}"#.utf8)
                )
            }

            XCTAssertEqual(path, "/api/session/compress")
            return apiTestJSONResponse(#"{"ok": true, "session": {"session_id": "abc123"}}"#, for: request)
        }

        let response = try await client.compressSession(id: "abc123")

        XCTAssertEqual(response.session?.sessionId, "abc123")
        XCTAssertEqual(paths, ["/api/session/compress/start", "/api/session/compress"])
    }

    func testCompressionSummaryExtractsCompressedTokenEstimate() {
        let arrowSummary = SessionCompressionSummary(
            headline: "Compressed: 20 -> 10 messages",
            tokenLine: "Approx request size: ~30,100 \u{2192} ~10,347 tokens",
            note: nil,
            referenceMessage: nil
        )
        let asciiSummary = SessionCompressionSummary(
            headline: nil,
            tokenLine: "Rough transcript estimate: ~1200 -> ~320 tokens",
            note: nil,
            referenceMessage: nil
        )

        XCTAssertEqual(arrowSummary.compressedTokenEstimate, 10_347)
        XCTAssertEqual(asciiSummary.compressedTokenEstimate, 320)
    }

    func testUndoSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/undo")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertNil(json?["sessionId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "removed_count": 2,
              "removed_preview": "Summarize the logs"
            }
            """, for: request)
        }

        let response = try await client.undoSession(id: "abc123")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.removedCount, 2)
        XCTAssertEqual(response.removedPreview, "Summarize the logs")
    }

    func testRetrySessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/retry")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertNil(json?["sessionId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "last_user_text": "Summarize the logs",
              "removed_count": 2
            }
            """, for: request)
        }

        let response = try await client.retrySession(id: "abc123")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.lastUserText, "Summarize the logs")
        XCTAssertEqual(response.removedCount, 2)
    }

    func testSessionMetadataRequestOmitsMessageLimitWhenNil() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "copy123")
            XCTAssertEqual(query["messages"], "0")
            XCTAssertNil(query["msg_limit"])

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "copy123",
                "title": "Planning (copy)",
                "message_count": 4
              }
            }
            """, for: request)
        }

        let response = try await client.session(id: "copy123", includeMessages: false, messageLimit: nil)

        XCTAssertEqual(response.session?.sessionId, "copy123")
        XCTAssertEqual(response.session?.title, "Planning (copy)")
        XCTAssertEqual(response.session?.messageCount, 4)
    }

    func testMoveSessionBuildsExpectedBodyAndDecodesMovedSession() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/move")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertEqual(json?["project_id"] as? String, "proj123")
            XCTAssertNil(json?["sessionId"])
            XCTAssertNil(json?["projectId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "session": {
                "session_id": "abc123",
                "project_id": "proj123"
              }
            }
            """, for: request)
        }

        let response = try await client.moveSession(id: "abc123", projectID: "proj123")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.session?.sessionId, "abc123")
        XCTAssertEqual(response.session?.projectId, "proj123")
    }

    func testMoveSessionToNoProjectOmitsProjectID() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/move")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertNil(json?["project_id"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "session": {
                "session_id": "abc123",
                "project_id": null
              }
            }
            """, for: request)
        }

        let response = try await client.moveSession(id: "abc123", projectID: nil)

        XCTAssertEqual(response.ok, true)
        XCTAssertNil(response.session?.projectId)
    }

    func testSessionMutatorMove503WithServerPayloadMapsToStreamingBusyError() async throws {
        // Upstream refuses a move while the session streams: 503 + JSON error payload.
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/move")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error": "Session is busy (streaming). Please try again in a moment."}"#.utf8))
        }

        do {
            try await SessionMutator(client: client).move(sessionID: "abc123", to: "proj123")
            XCTFail("Expected SessionMoveWhileStreamingError")
        } catch is SessionMoveWhileStreamingError {
            XCTAssertEqual(
                SessionMoveWhileStreamingError().errorDescription,
                String(localized: "This session is still responding, so it can't be moved yet. Try again when it finishes.")
            )
        }
    }

    func testSessionMutatorMoveProxy503WithoutJSONPayloadKeepsGenericAPIError() async throws {
        // A tunnel/proxy 503 serves HTML, not the server's JSON payload; keep the
        // generic connectivity message for that case (issue #25).
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("<html>Service Unavailable</html>".utf8))
        }

        do {
            try await SessionMutator(client: client).move(sessionID: "abc123", to: nil)
            XCTFail("Expected APIError.http(503)")
        } catch let error as APIError {
            guard case .http(let statusCode, _) = error else {
                return XCTFail("Expected APIError.http, got \(error)")
            }
            XCTAssertEqual(statusCode, 503)
        }
    }

    func testArchiveSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/archive")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertEqual(json?["archived"] as? Bool, true)

            return apiTestJSONResponse("""
            {
              "ok": true,
              "session": {
                "session_id": "abc123",
                "archived": true
              }
            }
            """, for: request)
        }

        let response = try await client.archiveSession(id: "abc123", archived: true)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.session?.archived, true)
    }

    func testUnarchiveSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/archive")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertEqual(json?["archived"] as? Bool, false)

            return apiTestJSONResponse("""
            {
              "ok": true,
              "session": {
                "session_id": "abc123",
                "archived": false
              }
            }
            """, for: request)
        }

        let response = try await client.archiveSession(id: "abc123", archived: false)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.session?.archived, false)
    }

    func testTruncateSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/truncate")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["session_id"] as? String, "session-abc")
            XCTAssertEqual(body?["keep_count"] as? Int, 3)

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "My chat",
                "messages": [
                  {"role": "user", "content": "Hello", "message_id": "m1"},
                  {"role": "assistant", "content": "Hi there", "message_id": "m2"},
                  {"role": "user", "content": "Thanks", "message_id": "m3"}
                ],
                "_messages_offset": 0
              }
            }
            """, for: request)
        }

        let response = try await client.truncateSession(id: "session-abc", keepCount: 3)

        XCTAssertEqual(response.session?.sessionId, "session-abc")
        XCTAssertEqual(response.session?.messages?.count, 3)
        XCTAssertEqual(response.session?.messagesOffset, 0)
    }
}
