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

    /// RSA-3072 no está en la tabla de TrustKit; la cabecera ASN.1 se verifica
    /// aquí contra una clave real. Generada con:
    ///
    ///   openssl req -x509 -newkey rsa:3072 -keyout k.pem -out c.pem \
    ///     -days 3650 -nodes -subj "/CN=pinning.test"
    ///   openssl x509 -in c.pem -pubkey -noout \
    ///     | openssl rsa -pubin -RSAPublicKey_out -outform DER | base64   # clave PKCS#1
    ///   openssl x509 -in c.pem -pubkey -noout \
    ///     | openssl pkey -pubin -outform DER | head -c 24 | xxd -p     # cabecera
    ///   → 308201a2300d06092a864886f70d01010105000382018f00
    @Test("RSA 3072")
    func rsa3072() throws {
        let key = try makeKey(base64: Self.rsa3072PKCS1, type: kSecAttrKeyTypeRSA)
        #expect(SPKIHasher.sha256Base64(of: key) == Self.rsa3072Pin)
    }

    /// El mismo vector por la ruta de producción: certificado DER →
    /// `SecCertificateCopyKey` → hash. Es lo que recorre `validate(serverTrust:)`
    /// y lo que un servidor con clave RSA-3072 presenta de verdad.
    @Test("RSA 3072 desde el certificado (ruta de producción)")
    func rsa3072FromCertificate() throws {
        let der = try #require(Data(base64Encoded: Self.rsa3072CertificateDER))
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let key = try #require(SecCertificateCopyKey(certificate))
        #expect(SPKIHasher.sha256Base64(of: key) == Self.rsa3072Pin)
    }

    /// Pin calculado con el comando del README:
    /// `openssl x509 -in c.pem -pubkey -noout | openssl pkey -pubin -outform DER
    ///  | openssl dgst -sha256 -binary | base64`
    private static let rsa3072Pin = "7MPw/Epx+blaKme8hPiycvozIV++UBXmB7RAmkFB4TA="

    private static let rsa3072PKCS1 = """
    MIIBigKCAYEAzDlHYFq1JzXKxN6eucKGu8bQf6ej+IGXNhxJgUN8EmcDPsPHv5dtZAjtPFN6Uh08BYGtkxWq7pY9ZGHCBWhBYK0m\
    2byPm5BwsqcbX4473fNwuyIiW1XXptyOmWcyoWdFuCkwazTsu2tK9geLOcH/eFqCmcnRoEuFtkRVhpo3IU9pdeMrRY0mAfaC4B/2\
    bUbN14qRCnNvnbrW94QEzSxe/wX5KYNPEORIjWjIZ3v+nA3GCNKecF3iSGLMP5TphEQ5nkAzR3o3ELY+941axX8HmbOW7JiJnKmG\
    Ev8Bl4/ZKthljcOeRm+gQyjCopIwI9RFkPHWogabWHW2cIrAdwwmo5iIzBLX/Vhr9FcwRfcd7c+IgT2AnNLd7hUs5ghhAY0vXEdh\
    CsYMrD+B+Z9Xn2JgiZ0R0hm0qgoRdRMTowfVWY3G8DRIzTy2V5O5g7HwDRRRuRmR4d11bcL4HXq31NV15yPS84tWCsjbteQ8Xcjy\
    yHnGpupmcEb22ac5hasICCKxAgMBAAE=
    """

    /// Certificado autofirmado de juguete (clave PÚBLICA, no protege nada):
    /// `openssl x509 -in c.pem -outform DER | base64`
    private static let rsa3072CertificateDER = """
    MIIEDzCCAnegAwIBAgIUG5cXkd7w93lWcp4QNV1Q++qhy8YwDQYJKoZIhvcNAQELBQAwFzEVMBMGA1UEAwwMcGlubmluZy50ZXN0\
    MB4XDTI2MDkwMjAyMzYxMFoXDTM2MDgzMDAyMzYxMFowFzEVMBMGA1UEAwwMcGlubmluZy50ZXN0MIIBojANBgkqhkiG9w0BAQEF\
    AAOCAY8AMIIBigKCAYEAzDlHYFq1JzXKxN6eucKGu8bQf6ej+IGXNhxJgUN8EmcDPsPHv5dtZAjtPFN6Uh08BYGtkxWq7pY9ZGHC\
    BWhBYK0m2byPm5BwsqcbX4473fNwuyIiW1XXptyOmWcyoWdFuCkwazTsu2tK9geLOcH/eFqCmcnRoEuFtkRVhpo3IU9pdeMrRY0m\
    AfaC4B/2bUbN14qRCnNvnbrW94QEzSxe/wX5KYNPEORIjWjIZ3v+nA3GCNKecF3iSGLMP5TphEQ5nkAzR3o3ELY+941axX8HmbOW\
    7JiJnKmGEv8Bl4/ZKthljcOeRm+gQyjCopIwI9RFkPHWogabWHW2cIrAdwwmo5iIzBLX/Vhr9FcwRfcd7c+IgT2AnNLd7hUs5ghh\
    AY0vXEdhCsYMrD+B+Z9Xn2JgiZ0R0hm0qgoRdRMTowfVWY3G8DRIzTy2V5O5g7HwDRRRuRmR4d11bcL4HXq31NV15yPS84tWCsjb\
    teQ8XcjyyHnGpupmcEb22ac5hasICCKxAgMBAAGjUzBRMB0GA1UdDgQWBBT/hLPDApTPWLaG6Lhw9jNz0RKUUjAfBgNVHSMEGDAW\
    gBT/hLPDApTPWLaG6Lhw9jNz0RKUUjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBgQBfTdbNFSsEUA6DTlUuDoZn\
    14J6H9tAwAVSppHhEIGqYMm9rOn7d456pGRzCKgoiv2wamHl+/xqumpWGEGWSb5qiL1e2vYrANpGniD+tkOgn47k3Jtmn4e50Vez\
    4ztmq1H8YZjSKPpGjc5qbzO6BAOUW9uAXoIFfgtnBsSQMyEhRa6pWn8XQpeCL+lc1G2RYuu3R/TK3EMINDRJhjfjNjvGkX3taNU1\
    BpWSuAAveVYEoV7GMe2LJWqowRm/IoTjF0lVqSPVnE3kR+FDKH+MclYf5BRZmSNAKPo/oCJU2yKa0zq8ye0h27G6XIL4WK+PyX1u\
    L2f55/voxg+WtNeI9Lcm5pCyepyddsGGLPShP/RENFpupu9ql8WShnQG6tcCqr1qXjNc7YYx49ms/1Lz6O9THtb0lqXiMiBcfqj8\
    ZJ+vDk295gOSEsdHMpDtyzU7BaTkdJZO3eCvDfnwaKLk1Pa5gggyB5ca53sS7wcwefJaEF3N4dtDveScENYry0tLg0Q=
    """

    @Test("RSA 4096")
    func rsa4096() throws {
        let key = try makeKey(
            base64: "MIICCgKCAgEAujc0Jhko+lc7iy8i0G1jQ5XUG89GPERPEr/nDfxL4DN9BPL9u7URgx/HQwoMKmwKWmwqdrGfo2U2VMu2tluIEePnfZ9clTSnbvca3MbaEWgp90FFnhDXABYePtaYlyyT4NhmA0uKi8T+B319/mV97vFcvQ6dANiuGWOHLz4mUIHsiwmM/ne1ch1rtVn5m5y9lYe4P4O6KaqYxUZbBe/aqeZEj68jLZ04SNfWFXR/CeoY6QioKmr1UrDVayFWPhyRvd4Z1mxNKMUT07vtSoVI5dFyDY5dck1eLLjAcEAOjTDtFKw88aPdQfO+WFm6LNHAFNqa5qIKov0hVSA28RZ2JjTXo9qnkQQ9ulRqp7JWC7MlcfJhU/xHyjuHeHZ830LhiYElAgTOfg+tO55ZZqeSbn3lqrrTYG3kVuSOH+d8dc0cnYtNwvuJhax+2Dr+ZH1AI8WzdzG/BWANnlmujxXy4KZMKXifvjdmAWq9FqhyIc2DDqjrbZzrtcOiAPKJsuB9zDBPMvK+IJugYYWxhqbgY90fJBJ9QJwbISauZ4naUdTcE76Dkh5NGSvRRyUVOIZwaqTOWxmgLamEVGrJl/C7aPtC1Xa4VJuCIiF6gLl3Bn+iCzviDEAhx1F5Be39BGw7zGTu+qj/hVPf29ze6/AgKqfnUFRDfPcf6GZ93Dh6pa0CAwEAAQ==",
            type: kSecAttrKeyTypeRSA
        )
        #expect(SPKIHasher.sha256Base64(of: key) == "yZ54sIDTzZ9yicn2CZstPF6HkXZM615ECn1eivsMYdI=")
    }
}

// MARK: - Invariantes del constructor (función pura, sin reventar)

/// Un pin base64 sintáctico de 32 bytes: lo único que el constructor acepta.
private func pin(_ byte: UInt8) -> String {
    Data(repeating: byte, count: 32).base64EncodedString()
}

@Suite("Pinning: invariantes de la configuración")
struct PinningInvariantTests {
    @Test("un solo pin se rechaza citando RFC 7469 (pin de respaldo)")
    func singlePinIsRejected() {
        let issue = SSLPinningConfiguration.validatePins([pin(0xA1)])
        #expect(issue == .tooFew(count: 1))
        #expect(issue?.description.contains("RFC 7469") == true)
    }

    @Test("lista vacía se rechaza")
    func emptyIsRejected() {
        #expect(SSLPinningConfiguration.validatePins([]) == .tooFew(count: 0))
    }

    @Test("pin que no es base64 se rechaza con su índice")
    func nonBase64IsRejected() {
        #expect(SSLPinningConfiguration.validatePins([pin(0xA1), "esto no es base64"]) == .notBase64(index: 1))
    }

    @Test("pin base64 que no mide 32 bytes se rechaza con su índice y tamaño")
    func wrongLengthIsRejected() {
        let corto = Data(repeating: 0xBB, count: 20).base64EncodedString()   // SHA-1, no SHA-256
        #expect(SSLPinningConfiguration.validatePins([corto, pin(0xA1)]) == .wrongLength(index: 0, bytes: 20))
    }

    @Test("dos pins válidos pasan")
    func twoValidPinsPass() {
        #expect(SSLPinningConfiguration.validatePins([pin(0xA1), pin(0xB2)]) == nil)
    }

    @Test("el init conserva pins, hosts y política de cadena")
    func initKeepsValues() {
        let config = SSLPinningConfiguration(publicKeyHashes: [pin(0xA1), pin(0xB2)], hosts: .only(["a.com"]))
        #expect(config.publicKeyHashes == [pin(0xA1), pin(0xB2)])
        #expect(config.hosts == .only(["a.com"]))
        #expect(config.chainValidation == .system)
    }

    @Test(".disabled sigue existiendo sin pins y sin hosts (no pasa por la precondition)")
    func disabledBypassesPrecondition() {
        #expect(SSLPinningConfiguration.disabled.publicKeyHashes.isEmpty)
        #expect(SSLPinningConfiguration.disabled.hosts == .only([]))
        #expect(SSLPinningConfiguration.disabled.requiresPinning(host: "cualquiera.com") == false)
    }

    /// El case no se puede envolver en `#if DEBUG`; la puerta está en el init.
    /// Los tests corren en DEBUG, así que aquí se verifica que NO dispara y
    /// que se respeta lo pedido. En un build sin DEBUG el init hace
    /// `assertionFailure` y degrada a `.system` (documentado en el tipo).
    @Test(".unsafeSkipForDevelopment en DEBUG no dispara y se conserva")
    func unsafeSkipIsHonouredInDebug() {
        #if DEBUG
        let config = SSLPinningConfiguration(
            publicKeyHashes: [pin(0xA1), pin(0xB2)],
            chainValidation: .unsafeSkipForDevelopment
        )
        #expect(config.chainValidation == .unsafeSkipForDevelopment)
        #else
        Issue.record("esta suite debe ejecutarse en DEBUG para verificar la puerta")
        #endif
    }

    #if os(macOS)
    /// La precondition de verdad, en proceso aparte. Solo macOS: los exit tests
    /// de Swift Testing no existen en iOS.
    @Test("un solo pin revienta el init con un mensaje que cita RFC 7469")
    func singlePinTrapsTheInit() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = SSLPinningConfiguration(publicKeyHashes: ["x"])
        }
        let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(stderr.contains("RFC 7469"))
    }
    #endif
}

// MARK: - Decisión de pinning (3 estados, lógica pura sin red)

@Suite("Pinning: decisión de 3 estados")
struct PinningDecisionTests {
    private let pinA = pin(0xA1)
    private let pinB = pin(0xB2)
    private let otro = pin(0xC3)

    @Test(".disabled es notApplicable para cualquier host (jamás useCredential a ciegas)")
    func disabledIsNotApplicable() {
        let result = SSLPinningConfiguration.disabled.decision(
            host: "api.example.com",
            chainTrusted: true,
            serverKeyHashes: [pinA]
        )
        #expect(result == .notApplicable)
    }

    @Test("host fuera de .only([...]) → notApplicable")
    func hostNotPinned() {
        let config = SSLPinningConfiguration(publicKeyHashes: [pinA, pinB], hosts: .only(["api.example.com"]))
        let result = config.decision(host: "cdn.example.com", chainTrusted: true, serverKeyHashes: [pinA])
        #expect(result == .notApplicable)
    }

    @Test(".all → el pinning aplica a todos los hosts")
    func allHostsPinsEverything() {
        let config = SSLPinningConfiguration(publicKeyHashes: [pinA, pinB], hosts: .all)
        #expect(config.decision(host: "cualquiera.com", chainTrusted: true, serverKeyHashes: [pinA]) == .validated)
    }

    @Test(".only([]) → ningún host se pinnea")
    func emptyOnlyPinsNothing() {
        let config = SSLPinningConfiguration(publicKeyHashes: [pinA, pinB], hosts: .only([]))
        #expect(config.decision(host: "api.example.com", chainTrusted: true, serverKeyHashes: [pinA]) == .notApplicable)
    }

    @Test("hash del servidor coincide → validated")
    func matchingHashValidates() {
        let config = SSLPinningConfiguration(publicKeyHashes: [pinA, pinB], hosts: .only(["api.example.com"]))
        #expect(config.decision(host: "api.example.com", chainTrusted: true, serverKeyHashes: [otro, pinB]) == .validated)
    }

    @Test("ningún hash coincide → failed")
    func noMatchFails() {
        let config = SSLPinningConfiguration(publicKeyHashes: [pinA, pinB], hosts: .only(["api.example.com"]))
        #expect(config.decision(host: "api.example.com", chainTrusted: true, serverKeyHashes: [otro]) == .failed)
    }

    @Test("cadena inválida → failed aunque el pin coincida")
    func brokenChainFails() {
        let config = SSLPinningConfiguration(publicKeyHashes: [pinA, pinB], hosts: .only(["api.example.com"]))
        #expect(config.decision(host: "api.example.com", chainTrusted: false, serverKeyHashes: [pinA]) == .failed)
    }

    @Test(".unsafeSkipForDevelopment no evalúa la cadena")
    func chainSkippedWhenDisabled() {
        let config = SSLPinningConfiguration(
            publicKeyHashes: [pinA, pinB],
            hosts: .only(["api.example.com"]),
            chainValidation: .unsafeSkipForDevelopment
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
