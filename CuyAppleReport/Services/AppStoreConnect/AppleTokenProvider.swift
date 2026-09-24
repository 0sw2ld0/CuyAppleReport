import CryptoKit
import Foundation

struct AppleTokenProvider {
    let issuerId: String
    let keyId: String
    let privateKey: P256.Signing.PrivateKey

    init(issuerId: String, keyId: String, pemData: Data) throws {
        self.issuerId = issuerId
        self.keyId = keyId
        self.privateKey = try P256.Signing.PrivateKey(pemRepresentation: String(decoding: pemData, as: UTF8.self))
    }

    func makeToken(now: Date = .now) throws -> String {
        let header = ["alg": "ES256", "kid": keyId, "typ": "JWT"]
        let issuedAt = Int(now.timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": issuerId, "iat": issuedAt, "exp": issuedAt + 20 * 60,
            "aud": "appstoreconnect-v1"
        ]
        let encodedHeader = try JSONSerialization.data(withJSONObject: header).base64URLEncoded()
        let encodedPayload = try JSONSerialization.data(withJSONObject: payload).base64URLEncoded()
        let signingInput = "\(encodedHeader).\(encodedPayload)"
        let signature = try privateKey.signature(for: Data(signingInput.utf8)).rawRepresentation
        return "\(signingInput).\(signature.base64URLEncoded())"
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
