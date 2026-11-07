import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(_CryptoExtras)
import _CryptoExtras
#endif

/// ID-token verification for the SIWC route (§3.2 step 6, D5): full JWS
/// signature check against OpenAI's JWKS, RS256 only, on macOS (Security)
/// and Linux (`_CryptoExtras`, pinned swift-crypto). No claim is trusted
/// before the signature and the iss/aud/azp/exp/iat/nonce checks pass.
enum SIWCJWT {
    struct Failure: Error, LocalizedError, Equatable {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { "ChatGPT sign-in could not be verified (\(reason)). Nothing was saved." }
    }

    struct Claims: Equatable {
        let sub: String
        let email: String?
        let emailVerified: Bool
        /// `https://api.openai.com/auth`.chatgpt_account_id when present.
        let accountId: String?
        let issuedAt: Int
        let expires: Int
    }

    /// A verified RSA public key (big-endian modulus and exponent, no leading zero).
    struct RSAKey: Equatable { let n: Data; let e: Data }

    static let skew: TimeInterval = 300

    // MARK: JWK

    /// Strict JWK → RSA key: kty RSA, alg RS256 when present, use sig when
    /// present, base64url integers without a leading zero octet, ≥ 2048 bits,
    /// odd exponent ≥ 3.
    static func rsaKey(_ jwk: [String: Any]) throws -> RSAKey {
        guard jwk["kty"] as? String == "RSA" else { throw Failure("JWK is not an RSA key") }
        if let alg = jwk["alg"], alg as? String != "RS256" { throw Failure("JWK alg is not RS256") }
        if let use = jwk["use"], use as? String != "sig" { throw Failure("JWK use is not sig") }
        func integer(_ name: String) throws -> Data {
            guard let text = jwk[name] as? String, let raw = SIWCEndpoint.base64URLDecode(text) else {
                throw Failure("JWK \(name) is not base64url")
            }
            guard let first = raw.first else { throw Failure("JWK \(name) is empty") }
            guard first != 0 else { throw Failure("JWK \(name) has a leading zero octet") }
            return raw
        }
        let n = try integer("n"), e = try integer("e")
        let bits = (n.count - 1) * 8 + (8 - n.first!.leadingZeroBitCount)
        guard bits >= 2048, n.count <= 1024 else { throw Failure("RSA key shorter than 2048 bits or too long") }
        guard e.count <= 8, let last = e.last, last & 1 == 1, !(e.count == 1 && e[e.startIndex] < 3) else {
            throw Failure("bad RSA exponent")
        }
        return RSAKey(n: n, e: e)
    }

    // MARK: Signature (platform)

    /// RSASSA-PKCS1-v1_5 with SHA-256 over `message`.
    static func verifyRS256(key: RSAKey, message: Data, signature: Data) -> Bool {
        guard signature.count == key.n.count else { return false }
        #if canImport(Security)
        let der = pkcs1PublicKeyDER(key)
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let secKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(secKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
        #elseif canImport(_CryptoExtras)
        guard let publicKey = try? _RSA.Signing.PublicKey(n: key.n, e: key.e) else { return false }
        return publicKey.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature), for: message,
                                          padding: .insecurePKCS1v1_5)
        #else
        return false
        #endif
    }

    /// DER `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`.
    static func pkcs1PublicKeyDER(_ key: RSAKey) -> Data {
        func length(_ count: Int) -> Data {
            if count < 0x80 { return Data([UInt8(count)]) }
            var bytes: [UInt8] = []; var value = count
            while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func integer(_ raw: Data) -> Data {
            var body = raw
            if let first = body.first, first & 0x80 != 0 { body.insert(0, at: 0) }
            return Data([0x02]) + length(body.count) + body
        }
        let content = integer(key.n) + integer(key.e)
        return Data([0x30]) + length(content.count) + content
    }

    // MARK: ID token

    static func decodeSegment(_ text: Substring) throws -> [String: Any] {
        guard let raw = SIWCEndpoint.base64URLDecode(String(text)), raw.count <= 65536,
              let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            throw Failure("undecodable token segment")
        }
        return object
    }

    /// Verify `token` against `jwks`; `refetch` is called at most once when
    /// the `kid` is unknown (bounded by the caller). `nonce` nil = refresh
    /// response (no nonce check). Returns the verified claims.
    static func verify(_ token: String, jwks: [String: Any], clientId: String, nonce: String?, now: Date,
                       refetch: (() async throws -> [String: Any])? = nil) async throws -> Claims {
        guard token.utf8.count <= 32768 else { throw Failure("ID token too large") }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else { throw Failure("not a JWS compact token") }
        let header = try decodeSegment(parts[0])
        let claims = try decodeSegment(parts[1])
        guard header["alg"] as? String == "RS256" else { throw Failure("algorithm refused (RS256 only)") }
        guard let kid = header["kid"] as? String, !kid.isEmpty, kid.utf8.count <= 256 else { throw Failure("missing kid") }
        func find(_ set: [String: Any]) throws -> [String: Any]? {
            let keys = (set["keys"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.filter { $0["kid"] as? String == kid }
            guard keys.count <= 1 else { throw Failure("ambiguous kid") }
            return keys.first
        }
        var jwk = try find(jwks)
        if jwk == nil, let refetch { jwk = try find(try await refetch()) }
        guard let jwk else { throw Failure("unknown kid") }
        let key = try rsaKey(jwk)
        guard let signature = SIWCEndpoint.base64URLDecode(String(parts[2])) else { throw Failure("bad signature encoding") }
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        guard verifyRS256(key: key, message: signed, signature: signature) else { throw Failure("bad signature") }
        // Claims only now.
        guard claims["iss"] as? String == SIWCEndpoint.issuer else { throw Failure("wrong issuer") }
        let audiences: [String]
        if let one = claims["aud"] as? String { audiences = [one] }
        else if let many = claims["aud"] as? [Any] { audiences = many.compactMap { $0 as? String } }
        else { audiences = [] }
        guard audiences.contains(clientId) else { throw Failure("audience does not contain the client") }
        if audiences.count > 1 && claims["azp"] == nil { throw Failure("multiple audiences without azp") }
        if let azp = claims["azp"], azp as? String != clientId { throw Failure("azp mismatch") }
        func integer(_ name: String) -> Int? {
            guard let number = claims[name] as? NSNumber, String(cString: number.objCType) != "c" else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value == value.rounded(), abs(value) < 1e12 else { return nil }
            return Int(value)
        }
        let nowSeconds = now.timeIntervalSince1970
        guard let exp = integer("exp"), Double(exp) >= nowSeconds - skew else { throw Failure("expired") }
        guard let iat = integer("iat"), Double(iat) <= nowSeconds + skew, Double(iat) >= nowSeconds - 86400 else {
            throw Failure("issued-at not sane")
        }
        if let nonce {
            guard let got = claims["nonce"] as? String, constantTimeEqual(got, nonce) else { throw Failure("nonce mismatch") }
        }
        guard let sub = claims["sub"] as? String, !sub.isEmpty, sub.utf8.count <= 512 else { throw Failure("no subject") }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let account = (auth?["chatgpt_account_id"] as? String).flatMap { $0.isEmpty || $0.utf8.count > 512 ? nil : $0 }
        let email = (claims["email"] as? String).flatMap { $0.utf8.count <= 512 ? $0 : nil }
        return Claims(sub: sub, email: email, emailVerified: claims["email_verified"] as? Bool == true,
                      accountId: account, issuedAt: iat, expires: exp)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
