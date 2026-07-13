import Testing
import Foundation
@testable import CloudScanKit

private func testConfiguration() -> OneDriveOAuthConfiguration {
    OneDriveOAuthConfiguration(
        clientID: "test-client",
        authEndpoint: URL(string: "https://login.example.com/authorize")!,
        tokenEndpoint: URL(string: "https://login.example.com/token")!
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
    accountID: String = "user-1"
) -> TokenBroker {
    TokenBroker(
        providerID: "onedrive",
        accountID: accountID,
        authorizer: OAuthAuthorizer(configuration: testConfiguration().oauthClient, transport: transport),
        tokenStore: store
    )
}

/// A store whose access token is valid far into the future.
private func liveStore(accountID: String = "user-1") -> InMemoryTokenStore {
    let store = InMemoryTokenStore()
    try! store.save(
        StoredCredentials(
            refreshToken: "refresh-1",
            accessToken: "access-live",
            accessTokenExpiry: Date().addingTimeInterval(3600)
        ),
        forProviderID: "onedrive", accountID: accountID
    )
    return store
}

private func makeClient(
    transport: FakeTransport,
    broker: TokenBroker,
    recorder: SleepRecorder = SleepRecorder()
) -> GraphAPIClient {
    var client = GraphAPIClient(transport: transport, broker: broker)
    client.sleep = { recorder.record($0) }
    // Deterministic full-jitter: use the whole ceiling.
    client.jitter = { $0 }
    return client
}

private let anyURL = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root?$select=id")!

@Suite(.serialized) struct OneDriveGraphAPIClientTests {
    @Test func testBackoffOn429HonorsRetryAfter() async throws {
        // Graph always sends Retry-After on a 429; the client sleeps exactly it.
        let transport = FakeTransport(responses: [
            .empty(429, headers: ["Retry-After": "3"]),
            .json(200, ["id": "root"])
        ])
        let recorder = SleepRecorder()
        let client = makeClient(
            transport: transport, broker: makeBroker(store: liveStore(), transport: transport),
            recorder: recorder
        )
        let data = try await client.get(anyURL)
        #expect(String(decoding: data, as: UTF8.self).contains("root"))
        #expect(recorder.durations == [.seconds(3)])
    }

    @Test func testBackoffWithoutRetryAfterUsesExponentialBase() async throws {
        let transport = FakeTransport(responses: [
            .empty(503), .empty(500), .json(200, ["id": "root"])
        ])
        let recorder = SleepRecorder()
        let client = makeClient(
            transport: transport, broker: makeBroker(store: liveStore(), transport: transport),
            recorder: recorder
        )
        _ = try await client.get(anyURL)
        // Full-jitter ceiling is 2^attempt: 1s then 2s.
        #expect(recorder.durations == [.seconds(1), .seconds(2)])
    }

    @Test func test401ForcesRefreshThenRetriesWithNewToken() async throws {
        // GET(401) → refresh POST(200 access-2) → GET retry(200).
        let transport = FakeTransport(responses: [
            .empty(401),
            .json(200, ["access_token": "access-2", "expires_in": 3600, "token_type": "Bearer"]),
            .json(200, ["id": "root"])
        ])
        let store = liveStore()
        let client = makeClient(
            transport: transport, broker: makeBroker(store: store, transport: transport)
        )
        let data = try await client.get(anyURL)
        #expect(String(decoding: data, as: UTF8.self).contains("root"))

        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-live")
        #expect(transport.requests[1].url == testConfiguration().tokenEndpoint) // the refresh POST
        #expect(transport.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
    }

    @Test func test400SurfacesGraphErrorMessage() async throws {
        // Graph wraps errors as {"error": {"code", "message"}}; the message
        // reaches the caller and there is no retry.
        let transport = FakeTransport(responses: [
            .json(400, ["error": ["code": "invalidRequest", "message": "Invalid $select field"]])
        ])
        let client = makeClient(
            transport: transport, broker: makeBroker(store: liveStore(), transport: transport)
        )
        await #expect(throws: OneDriveError.requestFailed(status: 400, message: "Invalid $select field")) {
            _ = try await client.get(anyURL)
        }
        #expect(transport.requests.count == 1)
    }

    @Test func test403PermissionErrorFailsFast() async throws {
        // A plain 403 is a real permission error, not throttling → no retry.
        let transport = FakeTransport(responses: [
            .json(403, ["error": ["code": "accessDenied", "message": "Access denied"]])
        ])
        let client = makeClient(
            transport: transport, broker: makeBroker(store: liveStore(), transport: transport)
        )
        await #expect(throws: OneDriveError.requestFailed(status: 403, message: "Access denied")) {
            _ = try await client.get(anyURL)
        }
        #expect(transport.requests.count == 1)
    }
}
