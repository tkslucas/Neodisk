import Testing
import Foundation
@testable import CloudScanKit

@Suite struct PKCETests {
    /// RFC 7636 Appendix B worked example.
    @Test func testRFC7636AppendixBVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func testGeneratedVerifierUsesUnreservedAlphabetAndLength() {
        let allowed = Set(PKCE.unreservedCharacters)
        for length in [43, 64, 128] {
            let pair = PKCE.generate(verifierLength: length)
            #expect(pair.verifier.count == length)
            #expect(pair.verifier.allSatisfy { allowed.contains($0) })
            #expect(pair.challenge == PKCE.challenge(for: pair.verifier))
        }
    }

    @Test func testVerifierLengthIsClampedToSpec() {
        #expect(PKCE.generate(verifierLength: 10).verifier.count == 43)
        #expect(PKCE.generate(verifierLength: 500).verifier.count == 128)
    }

    @Test func testChallengeHasNoBase64Padding() {
        let challenge = PKCE.challenge(for: "some-verifier-value-that-is-long-enough-xx")
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
    }
}
