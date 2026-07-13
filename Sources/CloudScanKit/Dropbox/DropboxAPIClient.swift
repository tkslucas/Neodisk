//
//  DropboxAPIClient.swift
//  Neodisk
//
//  A thin authenticated POST client for the Dropbox v2 RPC API. Every request
//  is stamped with a Bearer token from the TokenBroker. It handles the two
//  transient failures Dropbox throws at a bulk enumeration:
//
//    - 401 Unauthorized: the token went stale between mint and use. Force one
//      refresh through the broker and retry the request once.
//    - 429 / 5xx: back off exponentially with jitter, honoring either a server
//      Retry-After header or Dropbox's own JSON {"error":{"retry_after":n}},
//      up to `maxAttempts` tries.
//
//  Any other non-2xx surfaces as DropboxError.requestFailed carrying Dropbox's
//  `error_summary`. Task cancellation is checked before each try and while
//  sleeping between retries, so a cancelled scan stops promptly.
//
//  Dropbox RPC endpoints that take no arguments (get_current_account,
//  get_space_usage) must be POSTed with an empty body AND no Content-Type —
//  sending application/json with an empty body earns a 400. Endpoints that take
//  arguments get a JSON body with Content-Type application/json. `post` models
//  both: pass `jsonBody: nil` for the no-arg case.
//
//  NOTE: GoogleAPIClient and this share a near-identical retry/backoff/401
//  skeleton; a future pass may unify the provider clients behind one policy.
//

import Foundation

struct DropboxAPIClient: Sendable {
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

    /// Performs an authenticated POST and returns the response body, applying
    /// the refresh-on-401 and backoff-on-rate-limit policies. `jsonBody` nil
    /// sends an empty body with no Content-Type (the no-argument RPC form).
    func post(_ url: URL, jsonBody: Data? = nil) async throws -> Data {
        var retryCount = 0
        var didForceRefresh = false

        while true {
            try Task.checkCancellation()
            let token = try await broker.validToken()
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let jsonBody {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = jsonBody
            }

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
                let delay = backoffDelay(attempt: retryCount, response: response, body: data)
                retryCount += 1
                try await sleep(delay)
                continue
            }

            throw DropboxError.requestFailed(
                status: status,
                message: Self.errorMessage(from: data)
            )
        }
    }

    // MARK: - Retry policy

    /// 429 and 5xx are always transient. Dropbox does not overload 403 for
    /// rate limits the way Drive does, so a plain 403 is a real error.
    static func isRetryable(status: Int) -> Bool {
        status == 429 || (500..<600).contains(status)
    }

    private func backoffDelay(attempt: Int, response: HTTPURLResponse, body: Data) -> Duration {
        if let retryAfter = Self.retryAfterSeconds(response: response, body: body) {
            return .seconds(retryAfter)
        }
        let base = min(pow(2.0, Double(attempt)), maxBackoff)
        return .seconds(jitter(base))
    }

    /// Dropbox conveys a retry hint either in the Retry-After header (seconds
    /// or an HTTP date) or inside the JSON error body as
    /// {"error":{"retry_after":n}}; honor whichever is present, header first.
    static func retryAfterSeconds(response: HTTPURLResponse, body: Data) -> TimeInterval? {
        if let value = response.value(forHTTPHeaderField: "Retry-After") {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if let seconds = TimeInterval(trimmed) { return max(seconds, 0) }
            if let date = httpDateFormatter.date(from: trimmed) {
                return max(date.timeIntervalSinceNow, 0)
            }
        }
        if let seconds = retryAfterFromBody(body) { return max(TimeInterval(seconds), 0) }
        return nil
    }

    static func retryAfterFromBody(_ data: Data) -> Int? {
        try? JSONDecoder().decode(DropboxRetryEnvelope.self, from: data).error?.retryAfter
    }

    // MARK: - Error extraction

    /// Dropbox reports API errors as `{"error_summary": "...", "error": {...}}`;
    /// error_summary is the human-facing tag path.
    static func errorMessage(from data: Data) -> String? {
        let summary = try? JSONDecoder().decode(DropboxErrorEnvelope.self, from: data).errorSummary
        // Trim Dropbox's trailing "/." separators for a cleaner message.
        return summary.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/. ")) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

private struct DropboxErrorEnvelope: Decodable {
    let errorSummary: String?
    enum CodingKeys: String, CodingKey {
        case errorSummary = "error_summary"
    }
}

private struct DropboxRetryEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let retryAfter: Int?
        enum CodingKeys: String, CodingKey {
            case retryAfter = "retry_after"
        }
    }
    let error: ErrorBody?
}
