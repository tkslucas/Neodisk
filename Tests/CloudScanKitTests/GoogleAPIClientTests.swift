import Testing
import Foundation
@testable import CloudScanKit

private func testConfiguration() -> GoogleOAuthConfiguration {
    GoogleOAuthConfiguration(
        clientID: "test-client",
        clientSecret: "test-secret",
        authEndpoint: URL(string: "https://accounts.example.com/auth")!,
        tokenEndpoint: URL(string: "https://oauth.example.com/token")!,
        revokeEndpoint: URL(string: "https://oauth.example.com/revoke")!
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
    accountID: String = "perm-1",
    now: @escaping @Sendable () -> Date = { Date() }
) -> TokenBroker {
    TokenBroker(
        providerID: "google",
        accountID: accountID,
        authorizer: OAuthAuthorizer(configuration: testConfiguration().oauthClient, transport: transport),
        tokenStore: store,
        now: now
    )
}

/// A store whose access token is valid far into the future.
private func liveStore(accountID: String = "perm-1") -> InMemoryTokenStore {
    let store = InMemoryTokenStore()
    try! store.save(
        StoredCredentials(
            refreshToken: "refresh-1",
            accessToken: "access-live",
            accessTokenExpiry: Date().addingTimeInterval(3600)
        ),
        forProviderID: "google", accountID: accountID
    )
    return store
}

private func makeClient(
    transport: FakeTransport,
    broker: TokenBroker,
    recorder: SleepRecorder = SleepRecorder()
) -> GoogleAPIClient {
    var client = GoogleAPIClient(transport: transport, broker: broker)
    client.sleep = { recorder.record($0) }
    // Deterministic full-jitter: use the whole ceiling.
    client.jitter = { $0 }
    return client
}

private let anyURL = URL(string: "https://www.googleapis.com/drive/v3/files/root?fields=id")!

@Suite(.serialized) struct GoogleAPIClientTests {
    @Test func testBackoffOn429ThenSucceedsHonoringRetryAfter() async throws {
        let transport = FakeTransport(responses: [
            .empty(429, headers: ["Retry-After": "2"]),
            .json(200, ["id": "root"])
        ])
        let recorder = SleepRecorder()
        let client = makeClient(
            transport: transport, broker: makeBroker(store: liveStore(), transport: transport),
            recorder: recorder
        )

        let data = try await client.get(anyURL)
        #expect(String(decoding: data, as: UTF8.self).contains("root"))
        // Slept exactly the server-specified Retry-After, once.
        #expect(recorder.durations == [.seconds(2)])
    }

    @Test func testBackoffWithoutRetryAfterUsesExponentialBase() async throws {
        let transport = FakeTransport(responses: [
            .empty(500), .empty(503), .json(200, ["id": "root"])
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

    @Test func test403RateLimitRetries() async throws {
        let transport = FakeTransport(responses: [
            .json(403, ["error": ["errors": [["reason": "rateLimitExceeded"]]]]),
            .json(200, ["id": "root"])
        ])
        let client = makeClient(
            transport: transport, broker: makeBroker(store: liveStore(), transport: transport)
        )
        _ = try await client.get(anyURL)
        #expect(transport.requests.count == 2)
    }

    @Test func test403PermissionErrorFailsFast() async throws {
        let transport = FakeTransport(responses: [
            .json(403, ["error": ["message": "Insufficient permission",
                                   "errors": [["reason": "insufficientPermissions"]]]])
        ])
        let client = makeClient(
            transport: transport, broker: makeBroker(store: liveStore(), transport: transport)
        )
        await #expect(throws: GoogleDriveError.requestFailed(status: 403, message: "Insufficient permission")) {
            _ = try await client.get(anyURL)
        }
        #expect(transport.requests.count == 1)
    }

    @Test func test400FailsFastWithGoogleMessage() async throws {
        let transport = FakeTransport(responses: [
            .json(400, ["error": ["message": "Invalid field selection foo"]])
        ])
        let client = makeClient(
            transport: transport, broker: makeBroker(store: liveStore(), transport: transport)
        )
        await #expect(throws: GoogleDriveError.requestFailed(status: 400, message: "Invalid field selection foo")) {
            _ = try await client.get(anyURL)
        }
        #expect(transport.requests.count == 1) // no retry
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

        // First GET used the stored token; the retried GET carries the refreshed one.
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-live")
        #expect(transport.requests[1].url == testConfiguration().tokenEndpoint) // the refresh POST
        #expect(transport.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
        // Refresh persisted, so a subsequent read sees the new token.
        #expect(try store.load(forProviderID: "google", accountID: "perm-1")?.accessToken == "access-2")
    }

    @Test func testSingleFlightRefreshRunsExactlyOneRefreshPost() async throws {
        // One scripted refresh response; two concurrent callers must share it.
        let transport = FakeTransport(responses: [
            .json(200, ["access_token": "access-9", "expires_in": 3600, "token_type": "Bearer"])
        ])
        // Expired token forces both callers into a refresh.
        let store = InMemoryTokenStore()
        try store.save(
            StoredCredentials(
                refreshToken: "refresh-1",
                accessToken: "stale",
                accessTokenExpiry: Date().addingTimeInterval(-3600)
            ),
            forProviderID: "google", accountID: "perm-1"
        )
        let broker = makeBroker(store: store, transport: transport)

        async let first = broker.validToken()
        async let second = broker.validToken()
        let tokens = try await [first, second]

        #expect(tokens == ["access-9", "access-9"])
        // Exactly one refresh POST hit the token endpoint.
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].url == testConfiguration().tokenEndpoint)
    }

    @Test func testInvalidGrantOnRefreshBecomesAuthorizationRequired() async throws {
        let transport = FakeTransport(responses: [
            .json(400, ["error": "invalid_grant", "error_description": "Token has been expired or revoked."])
        ])
        let store = InMemoryTokenStore()
        try store.save(
            StoredCredentials(
                refreshToken: "dead",
                accessToken: "stale",
                accessTokenExpiry: Date().addingTimeInterval(-3600)
            ),
            forProviderID: "google", accountID: "perm-1"
        )
        let broker = makeBroker(store: store, transport: transport)

        await #expect(throws: CloudScanError.authorizationRequired) {
            _ = try await broker.validToken()
        }
    }
}
