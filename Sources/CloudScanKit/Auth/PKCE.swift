//
//  PKCE.swift
//  Neodisk
//
//  Proof Key for Code Exchange (RFC 7636). The loopback OAuth flow is a
//  public client, so it binds the authorization code to a per-request secret
//  (the verifier) whose S256 hash (the challenge) travels in the auth URL.
//

import Foundation
import Security
import CryptoKit

enum PKCE {
    /// A verifier / challenge pair for one authorization request.
    struct Pair: Equatable, Sendable {
        let verifier: String
        let challenge: String
    }

    /// RFC 7636 §4.1 "unreserved" alphabet: ALPHA / DIGIT / "-" / "." / "_" / "~".
    static let unreservedCharacters = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// A random verifier (43–128 chars) and its S256 challenge.
    static func generate(verifierLength: Int = 64) -> Pair {
        let length = min(max(verifierLength, 43), 128)
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        let verifier = String(bytes.map { unreservedCharacters[Int($0) % unreservedCharacters.count] })
        return Pair(verifier: verifier, challenge: challenge(for: verifier))
    }

    /// base64url(SHA256(ascii(verifier))) with padding stripped — the S256
    /// code_challenge_method.
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

extension Data {
    /// base64url encoding (RFC 4648 §5) with padding removed.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
