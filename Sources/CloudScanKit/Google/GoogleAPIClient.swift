//
//  GoogleAPIClient.swift
//  Neodisk
//
//  A thin authenticated GET client for the Drive REST API. Every request is
//  stamped with a Bearer token from the TokenBroker. It handles the two
//  transient failures Drive throws at a bulk enumeration:
//
//    - 401 Unauthorized: the token went stale between mint and use. Force one
//      refresh through the broker and retry the request once.
//    - 429 / 403 rate-limit / 5xx: back off exponentially with jitter,
//      honoring a server Retry-After, up to `maxAttempts` tries.
//
//  Any other non-2xx surfaces as GoogleDriveError.requestFailed carrying
//  Google's own error message. Task cancellation is checked before each try
//  and while sleeping between retries, so a cancelled scan stops promptly.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GoogleAPIClient: Sendable {
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
    /// the refresh-on-401 and backoff-on-rate-limit policies.
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

            if Self.isRetryable(status: status, body: data), retryCount < maxAttempts - 1 {
                let delay = backoffDelay(attempt: retryCount, response: response)
                retryCount += 1
                try await sleep(delay)
                continue
            }

            throw GoogleDriveError.requestFailed(
                status: status,
                message: Self.errorMessage(from: data)
            )
        }
    }

    // MARK: - Retry policy

    /// 429 and 5xx are always transient; a 403 is only transient when Drive
    /// reports a rate-limit reason (a plain 403 is a real permission error).
    static func isRetryable(status: Int, body: Data) -> Bool {
        if status == 429 { return true }
        if (500..<600).contains(status) { return true }
        if status == 403 {
            let reasons = errorReasons(from: body)
            return reasons.contains("userRateLimitExceeded")
                || reasons.contains("rateLimitExceeded")
        }
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

    /// Google wraps API errors as `{"error": {"message": …, "errors": [{"reason": …}]}}`.
    static func errorMessage(from data: Data) -> String? {
        try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data).error.message
    }

    static func errorReasons(from data: Data) -> [String] {
        guard let envelope = try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data) else {
            return []
        }
        return (envelope.error.errors ?? []).compactMap(\.reason)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

private struct GoogleErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        struct Item: Decodable { let reason: String? }
        let message: String?
        let errors: [Item]?
    }
    let error: ErrorBody
}
