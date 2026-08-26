import Foundation
import Security
import CryptoKit

// MARK: - Validation Result

/// Outcome of evaluating a server trust challenge against the pinning policy.
///
/// Three states, three dispositions — never a blind `.useCredential`:
/// - `notApplicable`: the host is not pinned (or pinning is disabled) → the
///   system performs its default TLS validation.
/// - `validated`: chain and pin checks passed → use the credential.
/// - `failed`: the connection must be cancelled.
public enum PinningValidationResult: Sendable, Equatable {
    case notApplicable
    case validated
    case failed
}

extension PinningValidationResult {
    /// Maps the validation result to the challenge disposition.
    var disposition: URLSession.AuthChallengeDisposition {
        switch self {
        case .notApplicable: .performDefaultHandling
        case .validated: .useCredential
        case .failed: .cancelAuthenticationChallenge
        }
    }
}

// MARK: - Configuration

/// Configuration for TLS public key pinning (SPKI, SHA-256, base64 — the same
/// pin format as TrustKit / HPKP).
///
/// ## Example
/// ```swift
/// let pinning = SSLPinningConfiguration(
///     publicKeyHashes: ["r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E="],
///     pinnedHosts: ["api.myapp.com"]
/// )
/// let service = APIService(configuration: configuration, sslPinning: pinning)
/// ```
///
/// ## How to compute a pin
/// ```bash
/// openssl s_client -connect api.example.com:443 < /dev/null \
///   | openssl x509 -pubkey -noout \
///   | openssl pkey -pubin -outform DER \
///   | openssl dgst -sha256 -binary | base64
/// ```
public struct SSLPinningConfiguration: Sendable, Equatable {
    /// Base64-encoded SHA-256 hashes of the pinned SubjectPublicKeyInfo (SPKI).
    /// At least one must match a key in the server's chain.
    public let publicKeyHashes: [String]

    /// Hosts to pin.
    /// - `nil`: pinning applies to ALL hosts.
    /// - Empty: no host is pinned (everything is `notApplicable`).
    /// - Otherwise: only the listed hosts are pinned.
    public let pinnedHosts: Set<String>?

    /// Whether to evaluate the certificate chain (`SecTrustEvaluateWithError`)
    /// before checking pins. Keep `true` in production; `false` only makes
    /// sense against self-signed certificates in development.
    public let validateCertificateChain: Bool

    public init(
        publicKeyHashes: [String],
        pinnedHosts: Set<String>? = nil,
        validateCertificateChain: Bool = true
    ) {
        self.publicKeyHashes = publicKeyHashes
        self.pinnedHosts = pinnedHosts
        self.validateCertificateChain = validateCertificateChain
    }

    /// Pinning disabled: every host is `notApplicable`, so the system performs
    /// its DEFAULT TLS validation for everything. It never blindly accepts.
    public static let disabled = SSLPinningConfiguration(
        publicKeyHashes: [],
        pinnedHosts: [],
        validateCertificateChain: true
    )

    // MARK: Pure decision core (testable without network or SecTrust)

    /// Whether `host` requires pinning under this configuration.
    public func requiresPinning(host: String) -> Bool {
        guard !publicKeyHashes.isEmpty else { return false }
        guard let pinnedHosts else { return true }
        return pinnedHosts.contains(host)
    }

    /// Pure 3-state decision. The autoclosures keep chain evaluation and key
    /// hashing lazy: neither runs when the host is not pinned, and the chain
    /// is not evaluated when `validateCertificateChain` is false.
    func decision(
        host: String,
        chainTrusted: @autoclosure () -> Bool,
        serverKeyHashes: @autoclosure () -> [String]
    ) -> PinningValidationResult {
        guard requiresPinning(host: host) else { return .notApplicable }
        if validateCertificateChain, !chainTrusted() { return .failed }
        let pinned = Set(publicKeyHashes)
        return serverKeyHashes().contains(where: pinned.contains) ? .validated : .failed
    }

    // MARK: Real evaluation

    /// Evaluates a server trust for `host` against this configuration.
    public func validate(serverTrust: SecTrust, host: String) -> PinningValidationResult {
        decision(
            host: host,
            chainTrusted: Self.evaluateChain(serverTrust),
            serverKeyHashes: Self.spkiHashes(from: serverTrust)
        )
    }

    private static func evaluateChain(_ serverTrust: SecTrust) -> Bool {
        var error: CFError?
        return SecTrustEvaluateWithError(serverTrust, &error)
    }

    private static func spkiHashes(from serverTrust: SecTrust) -> [String] {
        guard let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            return []
        }
        return certificates.compactMap { certificate in
            SecCertificateCopyKey(certificate).flatMap(SPKIHasher.sha256Base64(of:))
        }
    }
}

// MARK: - SPKI Hasher

/// Computes the standard SPKI SHA-256 pin of a public key: SHA-256 over the
/// DER SubjectPublicKeyInfo, reconstructed as ASN.1 header + the key's
/// external representation (X9.63 for EC, PKCS#1 for RSA).
enum SPKIHasher {
    /// Standard ASN.1 SPKI headers per key type/size (same table as TrustKit).
    private static let asn1Headers: [Header: [UInt8]] = [
        Header(keyType: kSecAttrKeyTypeRSA as String, keySizeInBits: 2048): [
            0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
            0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
        ],
        Header(keyType: kSecAttrKeyTypeRSA as String, keySizeInBits: 4096): [
            0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
            0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00
        ],
        Header(keyType: kSecAttrKeyTypeECSECPrimeRandom as String, keySizeInBits: 256): [
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
            0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
            0x42, 0x00
        ],
        Header(keyType: kSecAttrKeyTypeECSECPrimeRandom as String, keySizeInBits: 384): [
            0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
            0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00
        ]
    ]

    private struct Header: Hashable {
        let keyType: String
        let keySizeInBits: Int
    }

    /// Base64 SHA-256 SPKI pin of `publicKey`, or `nil` when the key type/size
    /// is unsupported (unsupported keys can never match a pin — fail closed).
    static func sha256Base64(of publicKey: SecKey) -> String? {
        guard
            let attributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any],
            let keyType = attributes[kSecAttrKeyType] as? String,
            let keySizeInBits = attributes[kSecAttrKeySizeInBits] as? Int,
            let header = asn1Headers[Header(keyType: keyType, keySizeInBits: keySizeInBits)],
            let keyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else {
            return nil
        }

        var spki = Data(header)
        spki.append(keyData)
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }
}
