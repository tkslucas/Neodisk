//
//  OAuthLoopbackServer.swift
//  Neodisk
//
//  A one-shot HTTP listener on 127.0.0.1 that catches the OAuth redirect.
//  Google's "loopback IP" flow redirects the browser to
//  http://127.0.0.1:<port>/?code=…&state=… after consent; this listener
//  binds an ephemeral port, serves a single close-this-tab page, and hands
//  the authorization code back to the awaiting authorizer.
//
//  Built on POSIX sockets rather than Network.framework's NWListener: the
//  socket API is dependency-light and binds a loopback listener reliably
//  across environments (NWListener refuses to bind in some sandboxes).
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum OAuthLoopbackError: Error, Equatable, Sendable {
    case listenerFailed(String)
    case timedOut
    case stateMismatch
    /// The `error=` query parameter Google returns when consent is denied.
    case authorizationDenied(String)
    case missingCode
    case cancelled
}

final class OAuthLoopbackServer: @unchecked Sendable {
    private let socketFD: Int32
    /// The ephemeral port the listener bound to.
    let port: UInt16

    /// accept() blocks a thread; the wait runs there. Closing the socket from
    /// another thread (timeout / cancel) unblocks it.
    private let acceptQueue = DispatchQueue(label: "app.neodisk.cloudscan.oauth-accept")
    private let timerQueue = DispatchQueue(label: "app.neodisk.cloudscan.oauth-timer")
    private let closeLock = NSLock()
    private var isClosed = false

    /// The redirect URI Google must send the browser back to. No trailing
    /// path — Google's loopback flow matches on scheme/host/port only.
    var redirectURI: String { "http://127.0.0.1:\(port)" }

    private init(socketFD: Int32, port: UInt16) {
        self.socketFD = socketFD
        self.port = port
    }

    /// Binds an ephemeral loopback port and returns a listener ready to accept
    /// the redirect.
    static func start() throws -> OAuthLoopbackServer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OAuthLoopbackError.listenerFailed("socket errno \(errno)") }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0 // kernel assigns an ephemeral port

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw OAuthLoopbackError.listenerFailed("bind errno \(errno)")
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw OAuthLoopbackError.listenerFailed("listen errno \(errno)")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        return OAuthLoopbackServer(socketFD: fd, port: UInt16(bigEndian: bound.sin_port))
    }

    /// Waits for the browser redirect and returns the authorization code.
    /// Rejects a mismatched `state`, surfaces an `error=` denial, and times
    /// out after `timeout`. Cancellable — a cancelled task stops the listener.
    func waitForCallback(
        expectedState: String,
        timeout: Duration = .seconds(300)
    ) async throws -> String {
        let box = ContinuationBox<String>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                box.set(continuation)

                timerQueue.asyncAfter(deadline: .now() + timeout.seconds) { [weak self] in
                    if box.resume(.failure(OAuthLoopbackError.timedOut)) { self?.stop() }
                }

                acceptQueue.async { [weak self] in
                    guard let self else { return }
                    let result = self.acceptCallback(expectedState: expectedState)
                    if box.resume(result) { self.stop() }
                }
            }
        } onCancel: {
            if box.resume(.failure(OAuthLoopbackError.cancelled)) { self.stop() }
        }
    }

    func stop() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        close(socketFD)
    }

    // MARK: - Accept loop

    /// Accepts connections until one carries an OAuth callback, serving a
    /// close-this-tab page. Stray requests (favicon, etc.) get a 204 and the
    /// loop continues. Returns `.cancelled` when the socket is closed under it.
    private func acceptCallback(expectedState: String) -> Result<String, Error> {
        while true {
            let connection = accept(socketFD, nil, nil)
            if connection < 0 {
                return .failure(OAuthLoopbackError.cancelled)
            }
            defer { close(connection) }

            guard let request = Self.readRequest(connection),
                  let target = Self.requestTarget(request) else {
                Self.write(connection, Self.httpResponse(status: "400 Bad Request", html: ""))
                continue
            }

            // Browsers fetch /favicon.ico and the like on the same origin;
            // answer and keep waiting so a stray request never resolves the
            // wait as a failure.
            guard Self.isCallbackTarget(target) else {
                Self.write(connection, Self.httpResponse(status: "204 No Content", html: ""))
                continue
            }

            let result = Self.parseCallback(target: target, expectedState: expectedState)
            let succeeded = (try? result.get()) != nil
            let html = succeeded ? Self.successHTML : Self.failureHTML
            Self.write(connection, Self.httpResponse(status: "200 OK", html: html))
            return result
        }
    }

    private static func readRequest(_ connection: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = recv(connection, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    private static func write(_ connection: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = send(connection, base + sent, data.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    // MARK: - Parsing

    /// The request-target of an HTTP request line ("GET /?… HTTP/1.1").
    static func requestTarget(_ request: String) -> String? {
        guard let firstLine = request.split(
            separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false
        ).first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    static func isCallbackTarget(_ target: String) -> Bool {
        guard let comps = URLComponents(string: "http://127.0.0.1\(target)") else { return false }
        let names = Set((comps.queryItems ?? []).map(\.name))
        return !names.isDisjoint(with: ["code", "error", "state"])
    }

    static func parseCallback(target: String, expectedState: String) -> Result<String, Error> {
        guard let comps = URLComponents(string: "http://127.0.0.1\(target)") else {
            return .failure(OAuthLoopbackError.missingCode)
        }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            return .failure(OAuthLoopbackError.authorizationDenied(error))
        }
        guard value("state") == expectedState else {
            return .failure(OAuthLoopbackError.stateMismatch)
        }
        guard let code = value("code"), !code.isEmpty else {
            return .failure(OAuthLoopbackError.missingCode)
        }
        return .success(code)
    }

    // MARK: - HTTP response

    private static func httpResponse(status: String, html: String) -> Data {
        let body = Data(html.utf8)
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        return Data(header.utf8) + body
    }

    private static let successHTML = page(
        title: "Neodisk connected",
        message: "You can close this tab and return to Neodisk."
    )
    private static let failureHTML = page(
        title: "Connection failed",
        message: "Something went wrong. You can close this tab and return to Neodisk."
    )

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width, initial-scale=1">\
        <title>Neodisk</title></head>\
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;\
        text-align:center;padding:3rem 1.5rem;color:#1c1c1e;background:#f5f5f7">\
        <h2 style="font-weight:600">\(title)</h2><p style="color:#6e6e73">\(message)</p>\
        </body></html>
        """
    }
}

/// One-shot continuation holder shared between the accept loop, the timeout,
/// and task cancellation; only the first `resume` wins.
private final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// Resumes exactly once; returns true for the call that consumed it.
    @discardableResult
    func resume(_ result: sending Result<T, Error>) -> Bool {
        lock.lock()
        guard let continuation else { lock.unlock(); return false }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}

private extension Duration {
    var seconds: Double {
        let (secs, attos) = components
        return Double(secs) + Double(attos) / 1e18
    }
}
