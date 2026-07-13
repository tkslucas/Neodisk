import Testing
import Foundation
@testable import CloudScanKit

private func testConfiguration() -> DropboxOAuthConfiguration {
    DropboxOAuthConfiguration(
        clientID: "test-app-key",
        authEndpoint: URL(string: "https://dropbox.example.com/authorize")!,
        tokenEndpoint: URL(string: "https://api.example.com/oauth2/token")!
    )
}

/// Records the delays a client would have slept, so backoff is asserted
/// without any real waiting.
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Duration] = []
    func record(_ duration: Duration) { lock.withLock { storage.append(duration) } }
    var durations: [Duration] { lock.withLock { storage } }
}

private func makeBroker(
    store: InMemoryTokenStore,
    transport: FakeTransport,
    accountID: String = "dbid:1"
) -> TokenBroker {
    TokenBroker(
        providerID: "dropbox",
        accountID: accountID,
        authorizer: OAuthAuthorizer(configuration: testConfiguration().oauthClient, transport: transport),
        tokenStore: store
    )
}

private func liveStore(accountID: String = "dbid:1") -> InMemoryTokenStore {
    let store = InMemoryTokenStore()
    try! store.save(
        StoredCredentials(
            refreshToken: "refresh-1",
            accessToken: "access-live",
            accessTokenExpiry: Date().addingTimeInterval(3600)
        ),
        forProviderID: "dropbox", accountID: accountID
    )
    return store
}

private func makeClient(
    transport: FakeTransport,
    broker: TokenBroker,
    recorder: SleepRecorder = SleepRecorder()
) -> DropboxAPIClient {
    var client = DropboxAPIClient(transport: transport, broker: broker)
    client.sleep = { recorder.record($0) }
    // Deterministic full-jitter: use the whole ceiling.
    client.jitter = { $0 }
    return client
}

private let anyURL = URL(string: "https://api.dropboxapi.com/2/users/get_space_usage")!

@Suite(.serialized) struct DropboxAPIClientTests {
    @Test func testBackoffOn429WithJSONRetryAfterThenSucceeds() async throws {
        // Dropbox 429 with the retry hint only in the JSON body (no header).
        let transport = FakeTransport(responses: [
            .json(429, ["error_summary": "too_many_requests/...",
                        "error": [".tag": "too_many_requests", "retry_after": 3]]),
            .json(200, ["used": 1, "allocation": ["allocated": 2]])
        ])
        let recorder = SleepRecorder()
        let client = makeClient(
            transport: transport, broker: makeBroker(store: liveStore(), transport: transport),
            recorder: recorder
        )

        let data = try await client.post(anyURL)
        #expect(String(decoding: data, as: UTF8.self).contains("allocation"))
        // Slept exactly the JSON-specified retry_after, once.
        #expect(recorder.durations == [.seconds(3)])
        #expect(transport.requests.count == 2)
    }

    @Test func testBackoffOn429WithRetryAfterHeaderTakesPrecedence() async throws {
        let transport = FakeTransport(responses: [
            .json(429, ["error_summary": "too_many_requests/.",
                        "error": ["retry_after": 9]], headers: ["Retry-After": "2"]),
            .json(200, ["used": 1, "allocation": ["allocated": 2]])
        ])
        let recorder = SleepRecorder()
        let client = makeClient(
            transport: transport, broker: makeBroker(store: liveStore(), transport: transport),
            recorder: recorder
        )
        _ = try await client.post(anyURL)
        #expect(recorder.durations == [.seconds(2)])
    }

    @Test func testBackoffOn5xxUsesExponentialBase() async throws {
        let transport = FakeTransport(responses: [
            .empty(500), .empty(503), .json(200, ["used": 1, "allocation": ["allocated": 2]])
        ])
        let recorder = SleepRecorder()
        let client = makeClient(
            transport: transport, broker: makeBroker(store: liveStore(), transport: transport),
            recorder: recorder
        )
        _ = try await client.post(anyURL)
        // Full-jitter ceiling is 2^attempt: 1s then 2s.
        #expect(recorder.durations == [.seconds(1), .seconds(2)])
    }

    @Test func testErrorSummarySurfacesInTypedError() async throws {
        let transport = FakeTransport(responses: [
            .json(409, ["error_summary": "path/not_found/.",
                        "error": [".tag": "path", "path": [".tag": "not_found"]]])
        ])
        let client = makeClient(
            transport: transport, broker: makeBroker(store: liveStore(), transport: transport)
        )
        await #expect(throws: DropboxError.requestFailed(status: 409, message: "path/not_found")) {
            _ = try await client.post(anyURL, jsonBody: Data("{}".utf8))
        }
        #expect(transport.requests.count == 1) // 409 is not retried
    }

    @Test func test401ForcesRefreshThenRetriesWithNewToken() async throws {
        // POST(401) → refresh POST(200 access-2) → POST retry(200).
        let transport = FakeTransport(responses: [
            .empty(401),
            .json(200, ["access_token": "access-2", "expires_in": 14400, "token_type": "bearer"]),
            .json(200, ["used": 1, "allocation": ["allocated": 2]])
        ])
        let store = liveStore()
        let client = makeClient(
            transport: transport, broker: makeBroker(store: store, transport: transport)
        )

        _ = try await client.post(anyURL)
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-live")
        #expect(transport.requests[1].url == testConfiguration().tokenEndpoint) // the refresh POST
        #expect(transport.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
        #expect(try store.load(forProviderID: "dropbox", accountID: "dbid:1")?.accessToken == "access-2")
    }

    @Test func testNoArgPostOmitsContentTypeAndBody() async throws {
        let transport = FakeTransport(responses: [.json(200, ["used": 1, "allocation": ["allocated": 2]])])
        let client = makeClient(
            transport: transport, broker: makeBroker(store: liveStore(), transport: transport)
        )
        _ = try await client.post(anyURL)
        #expect(transport.requests[0].value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(transport.bodies[0].isEmpty)

        let transport2 = FakeTransport(responses: [.json(200, ["used": 1, "allocation": ["allocated": 2]])])
        let client2 = makeClient(
            transport: transport2, broker: makeBroker(store: liveStore(), transport: transport2)
        )
        _ = try await client2.post(anyURL, jsonBody: Data(#"{"path":""}"#.utf8))
        #expect(transport2.requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(transport2.bodies[0] == #"{"path":""}"#)
    }
}
