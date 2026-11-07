import Foundation

extension SIWCSelftest {
    /// §3.2 step 6 / D5: one shared set of positive and negative vectors.
    static func jwtTests(_ root: URL, _ c: Checks) async throws {
        let v = SIWCSelftestVectors.self
        let jwks: [String: Any] = ["keys": [v.jwk1]]
        let now = vectorNow
        func verify(_ name: String, nonce: String? = v.nonce, client: String = v.clientId, set: [String: Any]? = nil,
                    at: Date? = nil, refetch: (() async throws -> [String: Any])? = nil) async -> Result<SIWCJWT.Claims, Error> {
            do { return .success(try await SIWCJWT.verify(v.tokens[name]!, jwks: set ?? jwks, clientId: client, nonce: nonce,
                                                         now: at ?? now, refetch: refetch)) }
            catch { return .failure(error) }
        }
        func ok(_ r: Result<SIWCJWT.Claims, Error>) -> SIWCJWT.Claims? { if case .success(let x) = r { return x }; return nil }
        func reason(_ r: Result<SIWCJWT.Claims, Error>) -> String { if case .failure(let e as SIWCJWT.Failure) = r { return e.reason }; return "" }

        let good = ok(await verify("good"))
        c.check("jwt: a good RS256 ID token verifies (signature, iss, aud, exp, iat, nonce)", good?.sub == v.sub)
        c.check("jwt: account and email are read only after verification", good?.accountId == "acct-A" && good?.emailVerified == true)
        let noNonceOK = ok(await verify("no_nonce", nonce: nil)) != nil
        let noNonceRefused = reason(await verify("no_nonce")) == "nonce mismatch"
        c.check("jwt: refresh responses skip the nonce check only when asked", noNonceOK && noNonceRefused)
        c.check("jwt: a wrong nonce is refused", reason(await verify("good", nonce: "OTHER")) == "nonce mismatch")
        c.check("jwt: several audiences with matching azp verify", ok(await verify("multi_aud_azp")) != nil)
        c.check("jwt: several audiences without azp are refused", reason(await verify("multi_aud_no_azp")) == "multiple audiences without azp")
        c.check("jwt: azp naming another client is refused", reason(await verify("azp_mismatch")) == "azp mismatch")
        c.check("jwt: wrong issuer refused", reason(await verify("wrong_iss")) == "wrong issuer")
        c.check("jwt: wrong audience refused", reason(await verify("wrong_aud")) == "audience does not contain the client")
        c.check("jwt: the issued client must be the audience", reason(await verify("good", client: "oaiappOther")) == "audience does not contain the client")
        c.check("jwt: expired refused (beyond 5 min skew)", reason(await verify("expired")) == "expired")
        c.check("jwt: exp within the skew still accepted", ok(await verify("good", at: Date(timeIntervalSince1970: TimeInterval(v.issuedAt + 3600 + 200)))) != nil)
        c.check("jwt: future iat refused", reason(await verify("iat_future")) == "issued-at not sane")
        c.check("jwt: a missing subject is refused", reason(await verify("no_sub")) == "no subject")
        c.check("jwt: a signature by another key under this kid is refused", reason(await verify("bad_sig")) == "bad signature")
        c.check("jwt: tampered claims are refused", reason(await verify("tampered")) == "bad signature")
        c.check("jwt: alg=none refused", ok(await verify("alg_none")) == nil)
        c.check("jwt: HS256 refused (RS256 only)", reason(await verify("alg_hs256")) == "algorithm refused (RS256 only)")
        c.check("jwt: a missing kid is refused", reason(await verify("no_kid")) == "missing kid")
        c.check("jwt: an unknown kid without refetch is refused", reason(await verify("good_other_kid")) == "unknown kid")
        var fetches = 0
        let refetched = ok(await verify("good_other_kid", refetch: { fetches += 1; return ["keys": [v.jwk1, v.jwk2]] }))
        c.check("jwt: an unknown kid triggers exactly one JWKS refetch", refetched != nil && fetches == 1)
        fetches = 0
        let still = await verify("good_other_kid", refetch: { fetches += 1; return ["keys": [v.jwk1]] })
        c.check("jwt: one refetch, then refused (bounded)", ok(still) == nil && fetches == 1)
        c.check("jwt: keys under 2048 bits refused", reason(await verify("short_key", set: ["keys": [v.jwk3]])) == "RSA key shorter than 2048 bits or too long")
        c.check("jwt: an ambiguous kid is refused", reason(await verify("good", set: ["keys": [v.jwk1, v.jwk1]])) == "ambiguous kid")

        // Malformed JWKs.
        func jwkVariant(_ change: (inout [String: Any]) -> Void) -> [String: Any] { var j = v.jwk1; change(&j); return ["keys": [j]] }
        let n = v.jwk1["n"] as! String
        let leadingZero = SIWCEndpoint.base64URL(Data([0]) + SIWCEndpoint.base64URLDecode(n)!)
        c.check("jwk: a leading zero octet in n is refused", reason(await verify("good", set: jwkVariant { $0["n"] = leadingZero })) == "JWK n has a leading zero octet")
        c.check("jwk: an empty exponent is refused", reason(await verify("good", set: jwkVariant { $0["e"] = "" })) == "JWK e is empty")
        c.check("jwk: non-base64url integers are refused", reason(await verify("good", set: jwkVariant { $0["n"] = n.replacingOccurrences(of: "-", with: "+") + "+" })) == "JWK n is not base64url")
        c.check("jwk: wrong kty is refused", reason(await verify("good", set: jwkVariant { $0["kty"] = "EC" })) == "JWK is not an RSA key")
        c.check("jwk: alg mismatch is refused", reason(await verify("good", set: jwkVariant { $0["alg"] = "RS512" })) == "JWK alg is not RS256")
        c.check("jwk: use other than sig is refused", reason(await verify("good", set: jwkVariant { $0["use"] = "enc" })) == "JWK use is not sig")
        c.check("jwk: an even exponent is refused", reason(await verify("good", set: jwkVariant { $0["e"] = "AQAA" })) == "bad RSA exponent")
        c.check("jwk: DER encodes the modulus as a positive INTEGER", SIWCJWT.pkcs1PublicKeyDER(try SIWCJWT.rsaKey(v.jwk1)).prefix(1) == Data([0x30]))
        c.check("jwt: oversized tokens are refused", (try? await SIWCJWT.verify(String(repeating: "a", count: 40000), jwks: jwks,
            clientId: v.clientId, nonce: nil, now: now)) == nil)
        _ = root
    }
}
