//
//  CloudTransport.swift
//  Neodisk
//
//  The HTTP seam every provider talks through, so OAuth and (later) Drive
//  enumeration can be driven by a scripted transport in tests without a
//  network. Production uses an ephemeral URLSession that keeps no cookies or
//  disk cache for the account.
//

import Foundation

public protocol CloudTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: CloudTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    public func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudTransportError.nonHTTPResponse
        }
        return (data, http)
    }
}

public enum CloudTransportError: Error, Equatable, Sendable {
    case nonHTTPResponse
}
