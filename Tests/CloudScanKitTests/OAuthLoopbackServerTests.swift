import Testing
import Foundation
@testable import CloudScanKit

/// Real ephemeral listener exercised over the loopback interface with
/// URLSession, so the parsing and HTML response paths are covered end to end.
@Suite(.serialized) struct OAuthLoopbackServerTests {
    @Test func testReturnsCodeAndServesHTMLOnSuccess() async throws {
        let server = try OAuthLoopbackServer.start()
        let redirect = server.redirectURI

        async let code = server.waitForCallback(expectedState: "state-123")

        var components = URLComponents(string: redirect)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "auth-code-abc"),
            URLQueryItem(name: "state", value: "state-123")
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)

        let received = try await code
        #expect(received == "auth-code-abc")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let html = String(decoding: data, as: UTF8.self)
        #expect(html.contains("close this tab"))
    }

    @Test func testStateMismatchThrows() async throws {
        let server = try OAuthLoopbackServer.start()
        async let code = server.waitForCallback(expectedState: "expected")

        var components = URLComponents(string: server.redirectURI)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "x"),
            URLQueryItem(name: "state", value: "wrong")
        ]
        _ = try? await URLSession.shared.data(from: components.url!)

        var thrown: Error?
        do { _ = try await code } catch { thrown = error }
        #expect(thrown as? OAuthLoopbackError == .stateMismatch)
    }

    @Test func testAuthorizationDeniedThrows() async throws {
        let server = try OAuthLoopbackServer.start()
        async let code = server.waitForCallback(expectedState: "state-1")

        var components = URLComponents(string: server.redirectURI)!
        components.queryItems = [
            URLQueryItem(name: "error", value: "access_denied"),
            URLQueryItem(name: "state", value: "state-1")
        ]
        _ = try? await URLSession.shared.data(from: components.url!)

        var thrown: Error?
        do { _ = try await code } catch { thrown = error }
        #expect(thrown as? OAuthLoopbackError == .authorizationDenied("access_denied"))
    }
}
