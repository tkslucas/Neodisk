import Foundation
@testable import CloudScanKit

/// A CloudTransport that replies with scripted responses and records the
/// requests (and their form bodies) it received.
final class FakeTransport: CloudTransport, @unchecked Sendable {
    struct StubResponse {
        let status: Int
        let body: Data

        static func json(_ status: Int, _ object: [String: Any]) -> StubResponse {
            StubResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }

        static func empty(_ status: Int) -> StubResponse {
            StubResponse(status: status, body: Data())
        }
    }

    private let lock = NSLock()
    private var responses: [StubResponse]
    private var recordedRequests: [URLRequest] = []
    private var recordedBodies: [String] = []

    init(responses: [StubResponse]) {
        self.responses = responses
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }

    var bodies: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedBodies
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response: StubResponse = lock.withLock {
            recordedRequests.append(request)
            recordedBodies.append(request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "")
            return responses.isEmpty ? StubResponse.empty(500) : responses.removeFirst()
        }

        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response.body, http)
    }
}
