//
//  GraphAPIClient.swift
//  Neodisk
//
//  A thin authenticated GET client for the Microsoft Graph REST API. Every
//  request is stamped with a Bearer token from the TokenBroker. It handles the
//  transient failures Graph throws at a bulk enumeration:
//
//    - 401 Unauthorized: the token went stale between mint and use. Force one
//      refresh through the broker and retry the request once.
//    - 429 / 503: back off, honoring the Retry-After header Graph's throttling
//      always sends, falling back to exponential backoff with jitter.
//    - other 5xx: back off exponentially with jitter, up to `maxAttempts`.
//
//  Any other non-2xx surfaces as OneDriveError.requestFailed carrying Graph's
//  own {"error": {"code", "message"}}. Task cancellation is checked before each
//  try and while sleeping between retries, so a cancelled scan stops promptly.
//
//  This deliberately mirrors GoogleAPIClient; the two provider clients differ
//  only in their retry predicate and error envelope, and are candidates for a
//  future single provider-neutral HTTP client.
//

import Foundation

struct GraphAPIClient: Sendable {
    let transport: any CloudTransport
    let broker: TokenBroker
    /// Total tries for a backoff-eligible failure before giving up.
    var maxAttempts: Int = 5
    /// Ceiling for the exponential base delay, before jitter.
    var maxBackoff: TimeInterval = 32
    /// Injected so tests can run without real waiting.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Full-jitter source: given a ceiling, returns a value in 0...ceiling.
    /// Injected so tests get deterministic delays.
    var jitter: @Sendable (TimeInterval) -> TimeInterval = { Double.random(in: 0...$0) }

    /// Performs an authenticated GET and returns the response body, applying
    /// the refresh-on-401 and backoff-on-throttle policies.
    func get(_ url: URL) async throws -> Data {
        var retryCount = 0
        var didForceRefresh = false

        while true {
            try Task.checkCancellation()
            let token = try await broker.validToken()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await transport.execute(request)
            let status = response.statusCode
            if (200..<300).contains(status) {
                return data
            }

            // A stale token: refresh once, unconditionally, then retry.
            if status == 401 && !didForceRefresh {
                didForceRefresh = true
                _ = try await broker.forceRefresh()
                continue
            }

            if Self.isRetryable(status: status), retryCount < maxAttempts - 1 {
                let delay = backoffDelay(attempt: retryCount, response: response)
                retryCount += 1
                try await sleep(delay)
                continue
            }

            throw OneDriveError.requestFailed(
                status: status,
                message: Self.errorMessage(from: data)
            )
        }
    }

    // MARK: - Retry policy

    /// Graph signals throttling with 429 and, under load, 503; both are
    /// transient. Other 5xx are transient too. Everything else is a real
    /// error (auth, permission, bad request) that must fail fast.
    static func isRetryable(status: Int) -> Bool {
        if status == 429 { return true }
        if (500..<600).contains(status) { return true }
        return false
    }

    private func backoffDelay(attempt: Int, response: HTTPURLResponse) -> Duration {
        if let retryAfter = Self.retryAfterSeconds(response) {
            return .seconds(retryAfter)
        }
        let base = min(pow(2.0, Double(attempt)), maxBackoff)
        return .seconds(jitter(base))
    }

    /// Retry-After is either a delay in seconds or an HTTP date; support both.
    static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) { return max(seconds, 0) }
        if let date = httpDateFormatter.date(from: trimmed) {
            return max(date.timeIntervalSinceNow, 0)
        }
        return nil
    }

    // MARK: - Error extraction

    /// Graph wraps API errors as `{"error": {"code": …, "message": …}}`.
    static func errorMessage(from data: Data) -> String? {
        try? JSONDecoder().decode(GraphErrorEnvelope.self, from: data).error.message
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

private struct GraphErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let code: String?
        let message: String?
    }
    let error: ErrorBody
}
