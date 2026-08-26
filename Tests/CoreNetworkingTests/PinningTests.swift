import Testing
import Foundation
import Security
@testable import CoreNetworking

// MARK: - SPKI hashing contra vectores de openssl

/// Vectores generados con openssl (ver comandos). El pin esperado es
/// `openssl dgst -sha256 -binary <spki.der> | base64` y la clave embebida es la
/// "external representation" que consume SecKeyCreateWithData (X9.63 para EC,
/// PKCS#1 para RSA), es decir, el SPKI sin su cabecera ASN.1 — exactamente lo
/// que la implementación debe reconstruir.
@Suite("SPKI hashing (vectores openssl)")
struct SPKIHashingTests {
    private func makeKey(base64: String, type: CFString) throws -> SecKey {
        let data = try #require(Data(base64Encoded: base64))
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: type,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error)
        return try #require(key)
    }

    @Test("EC P-256")
    func ecP256() throws {
        // openssl ecparam -name prime256v1 -genkey | openssl ec -pubout -outform DER
        let key = try makeKey(
            base64: "BFwbfeSo5F1m91FRIB1osE00VANg9QxTwrEGNwk5R/t+1mMKwrePVQZ4gIOvArSNklvGU/DvBttfiyuOjyCgDuA=",
            type: kSecAttrKeyTypeECSECPrimeRandom
        )
        #expect(SPKIHasher.sha256Base64(of: key) == "D7+/Dq0m8D4rI/5hRWKpC0RyU9ZKOZ9D6eBuXU22s0Q=")
    }

    @Test("EC P-384")
    func ecP384() throws {
        let key = try makeKey(
            base64: "BLSlomqxmlJub9BS0EG0lup0+4E0SF0l8VOsJVCvVTxk+3qGJ8c5Q6WohgBica/HvNTvtczxKyr/MphDn61oU3ks8bjqONknUa12hr3GhOlmAmywQAbWkV00bEMDc5ibYw==",
            type: kSecAttrKeyTypeECSECPrimeRandom
        )
        #expect(SPKIHasher.sha256Base64(of: key) == "ea+LL2VjfxBUj0Soz1SvGai2tzppLoSGedlK3A6ch9I=")
    }

    @Test("RSA 2048")
    func rsa2048() throws {
        let key = try makeKey(
            base64: "MIIBCgKCAQEAxs9doKvzSpIzhCPMKr2+zIsPTaMooVDBcQGc5VjVyEdJRMu3a4zbAnH8xQKud3MqfK9snEJEJ/myYhFA7UpgFqBdow1i+HD0jHKiW89zE3poGueoWjrfSjbUqjhThrroHN2nnKwN4YcLk/1+oVaDvGhT3eAkubXycB789hP5Tk7LvdWHKr1J6hYWdtx2T0EtCJTi2jtYWU3lzgae6oO8TbdpLgL0DyeOCOd5Rs5w6jXjqs2mfJ8LKRY/m0rz6xaupvUgTgpm9ev1GIySRrURGaatdNH3pUMyOnUkx8HZrTLUqQUTZjq8arrE4hXYcZLg2sjaXqD9l/74oZhFwglljQIDAQAB",
            type: kSecAttrKeyTypeRSA
        )
        #expect(SPKIHasher.sha256Base64(of: key) == "MnB3l1Lb2umgpJJ/9Y2dGQrrGOp3chVvOZczYCKVfTM=")
    }

    @Test("RSA 4096")
    func rsa4096() throws {
        let key = try makeKey(
            base64: "MIICCgKCAgEAujc0Jhko+lc7iy8i0G1jQ5XUG89GPERPEr/nDfxL4DN9BPL9u7URgx/HQwoMKmwKWmwqdrGfo2U2VMu2tluIEePnfZ9clTSnbvca3MbaEWgp90FFnhDXABYePtaYlyyT4NhmA0uKi8T+B319/mV97vFcvQ6dANiuGWOHLz4mUIHsiwmM/ne1ch1rtVn5m5y9lYe4P4O6KaqYxUZbBe/aqeZEj68jLZ04SNfWFXR/CeoY6QioKmr1UrDVayFWPhyRvd4Z1mxNKMUT07vtSoVI5dFyDY5dck1eLLjAcEAOjTDtFKw88aPdQfO+WFm6LNHAFNqa5qIKov0hVSA28RZ2JjTXo9qnkQQ9ulRqp7JWC7MlcfJhU/xHyjuHeHZ830LhiYElAgTOfg+tO55ZZqeSbn3lqrrTYG3kVuSOH+d8dc0cnYtNwvuJhax+2Dr+ZH1AI8WzdzG/BWANnlmujxXy4KZMKXifvjdmAWq9FqhyIc2DDqjrbZzrtcOiAPKJsuB9zDBPMvK+IJugYYWxhqbgY90fJBJ9QJwbISauZ4naUdTcE76Dkh5NGSvRRyUVOIZwaqTOWxmgLamEVGrJl/C7aPtC1Xa4VJuCIiF6gLl3Bn+iCzviDEAhx1F5Be39BGw7zGTu+qj/hVPf29ze6/AgKqfnUFRDfPcf6GZ93Dh6pa0CAwEAAQ==",
            type: kSecAttrKeyTypeRSA
        )
        #expect(SPKIHasher.sha256Base64(of: key) == "yZ54sIDTzZ9yicn2CZstPF6HkXZM615ECn1eivsMYdI=")
    }
}

// MARK: - Decisión de pinning (3 estados, lógica pura sin red)

@Suite("Pinning: decisión de 3 estados")
struct PinningDecisionTests {
    private let pinA = "aaaa+base64+pin+A="
    private let pinB = "bbbb+base64+pin+B="

    @Test(".disabled es notApplicable para cualquier host (jamás useCredential a ciegas)")
    func disabledIsNotApplicable() {
        let result = SSLPinningConfiguration.disabled.decision(
            host: "api.example.com",
            chainTrusted: true,
            serverKeyHashes: [pinA]
        )
        #expect(result == .notApplicable)
    }

    @Test("host fuera de la lista de pinned → notApplicable")
    func hostNotPinned() {
        let config = SSLPinningConfiguration(publicKeyHashes: [pinA], pinnedHosts: ["api.example.com"])
        let result = config.decision(host: "cdn.example.com", chainTrusted: true, serverKeyHashes: [pinA])
        #expect(result == .notApplicable)
    }

    @Test("pinnedHosts nil → el pinning aplica a todos los hosts")
    func nilHostsPinsEverything() {
        let config = SSLPinningConfiguration(publicKeyHashes: [pinA], pinnedHosts: nil)
        #expect(config.decision(host: "cualquiera.com", chainTrusted: true, serverKeyHashes: [pinA]) == .validated)
    }

    @Test("hash del servidor coincide → validated")
    func matchingHashValidates() {
        let config = SSLPinningConfiguration(publicKeyHashes: [pinA, pinB], pinnedHosts: ["api.example.com"])
        #expect(config.decision(host: "api.example.com", chainTrusted: true, serverKeyHashes: ["otro", pinB]) == .validated)
    }

    @Test("ningún hash coincide → failed")
    func noMatchFails() {
        let config = SSLPinningConfiguration(publicKeyHashes: [pinA], pinnedHosts: ["api.example.com"])
        #expect(config.decision(host: "api.example.com", chainTrusted: true, serverKeyHashes: ["otro"]) == .failed)
    }

    @Test("cadena inválida → failed aunque el pin coincida")
    func brokenChainFails() {
        let config = SSLPinningConfiguration(publicKeyHashes: [pinA], pinnedHosts: ["api.example.com"])
        #expect(config.decision(host: "api.example.com", chainTrusted: false, serverKeyHashes: [pinA]) == .failed)
    }

    @Test("validateCertificateChain=false no evalúa la cadena")
    func chainSkippedWhenDisabled() {
        let config = SSLPinningConfiguration(
            publicKeyHashes: [pinA],
            pinnedHosts: ["api.example.com"],
            validateCertificateChain: false
        )
        // chainTrusted es autoclosure: si se evaluara, este test fallaría.
        let result = config.decision(
            host: "api.example.com",
            chainTrusted: { Issue.record("la cadena no debía evaluarse"); return false }(),
            serverKeyHashes: [pinA]
        )
        #expect(result == .validated)
    }

    @Test("mapeo resultado → disposition del challenge")
    func dispositionMapping() {
        #expect(PinningValidationResult.notApplicable.disposition == .performDefaultHandling)
        #expect(PinningValidationResult.validated.disposition == .useCredential)
        #expect(PinningValidationResult.failed.disposition == .cancelAuthenticationChallenge)
    }
}
