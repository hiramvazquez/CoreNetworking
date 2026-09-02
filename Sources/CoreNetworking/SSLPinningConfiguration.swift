import CryptoKit
import Foundation
import Security

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
/// pin format as TrustKit / HPKP / `NSPinnedDomains`).
///
/// Before reaching for this type, consider Apple's declarative pinning
/// (`NSAppTransportSecurity` → `NSPinnedDomains`, iOS 14+): zero code, covers
/// every `URLSession` in the process, and uses this very same pin format. The
/// programmatic configuration below is for what the plist cannot do — pins
/// fetched or rotated remotely, hosts decided at runtime. See the README.
///
/// ## Example
/// ```swift
/// let pinning = SSLPinningConfiguration(
///     publicKeyHashes: [
///         "r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E=",   // current key
///         "Vjs8r4z+80wjNcr1YKepWQboSIRi63WsWXhIMN+eWys="    // backup key (RFC 7469)
///     ],
///     hosts: .only(["api.myapp.com"])
/// )
/// let service = APIService(configuration: configuration, sslPinning: pinning)
/// ```
///
/// ## Invariants (enforced with `precondition` in `init`)
/// - At least **two** pins. RFC 7469 §2.5 requires a backup pin: with a single
///   pin, rotating the server key leaves every installed app unable to connect
///   until an update ships. The backup pin is computed from a key you already
///   hold but have not deployed yet (see the README for the openssl command).
/// - Every pin is valid base64 decoding to exactly 32 bytes (a SHA-256).
///
/// Use ``validatePins(_:)`` first when the pins come from an untrusted or
/// remote source, so a malformed payload is handled instead of trapping.
///
/// ## How to compute a pin
/// ```bash
/// openssl s_client -connect api.example.com:443 < /dev/null \
///   | openssl x509 -pubkey -noout \
///   | openssl pkey -pubin -outform DER \
///   | openssl dgst -sha256 -binary | base64
/// ```
public struct SSLPinningConfiguration: Sendable, Equatable {
    /// Which hosts the pins apply to.
    public enum Hosts: Sendable, Equatable {
        /// Every host the session talks to is pinned.
        case all
        /// Only the listed hosts are pinned; any other host gets the system's
        /// default TLS validation. `.only([])` pins nothing.
        case only(Set<String>)
    }

    /// Whether the certificate chain is evaluated before comparing pins.
    public enum ChainValidation: Sendable, Equatable {
        /// `SecTrustEvaluateWithError` must succeed before pins are compared.
        /// This is the only option that should ever reach production.
        case system

        /// Skip chain evaluation and compare pins only. Exists solely for
        /// development against self-signed certificates.
        ///
        /// A Swift `enum` case cannot be wrapped in `#if DEBUG`, so the gate
        /// lives in `init` instead: in a build **without** `DEBUG` this case
        /// triggers `assertionFailure` and the configuration is created with
        /// `.system` anyway (fail closed — a self-signed staging certificate
        /// then fails visibly instead of being accepted silently). In `DEBUG`
        /// it is honoured as requested.
        case unsafeSkipForDevelopment
    }

    /// Why a list of pins is not acceptable. See ``validatePins(_:)``.
    public enum PinIssue: Sendable, Equatable, CustomStringConvertible {
        /// Fewer than two pins (RFC 7469 §2.5: a backup pin is mandatory).
        case tooFew(count: Int)
        /// The pin at `index` is not valid base64.
        case notBase64(index: Int)
        /// The pin at `index` decodes to `bytes` bytes instead of 32.
        case wrongLength(index: Int, bytes: Int)

        public var description: String {
            switch self {
            case .tooFew(let count):
                "SSLPinningConfiguration requires at least 2 pins (RFC 7469 §2.5: a backup pin "
                    + "for the key you will rotate to), got \(count). With a single pin, rotating "
                    + "the server key locks every installed app out until an update ships."
            case .notBase64(let index):
                "SSLPinningConfiguration: pin at index \(index) is not valid base64 "
                    + "(expected the base64 SHA-256 of the SubjectPublicKeyInfo)."
            case .wrongLength(let index, let bytes):
                "SSLPinningConfiguration: pin at index \(index) decodes to \(bytes) bytes, "
                    + "expected 32 (a SHA-256 digest)."
            }
        }
    }

    /// Base64-encoded SHA-256 hashes of the pinned SubjectPublicKeyInfo (SPKI).
    /// At least one must match a key in the server's chain.
    public let publicKeyHashes: [String]

    /// Hosts to pin. See ``Hosts``.
    public let hosts: Hosts

    /// Chain evaluation policy. See ``ChainValidation`` for the `DEBUG` gate.
    public let chainValidation: ChainValidation

    /// Creates a pinning configuration.
    ///
    /// - Precondition: `publicKeyHashes` passes ``validatePins(_:)`` — at least
    ///   two pins, each valid base64 of 32 bytes. Violations trap with a
    ///   message that names the rule (RFC 7469 backup pin) — pins are build-time
    ///   constants, a typo should not reach the store.
    public init(
        publicKeyHashes: [String],
        hosts: Hosts = .all,
        chainValidation: ChainValidation = .system
    ) {
        if let issue = Self.validatePins(publicKeyHashes) {
            preconditionFailure(issue.description)
        }
        self.init(
            uncheckedPublicKeyHashes: publicKeyHashes,
            hosts: hosts,
            chainValidation: Self.gatedForDevelopment(chainValidation)
        )
    }

    /// Memberwise init without the pin precondition, for `.disabled` only.
    private init(uncheckedPublicKeyHashes: [String], hosts: Hosts, chainValidation: ChainValidation) {
        self.publicKeyHashes = uncheckedPublicKeyHashes
        self.hosts = hosts
        self.chainValidation = chainValidation
    }

    /// Pinning disabled: every host is `notApplicable`, so the system performs
    /// its DEFAULT TLS validation for everything. It never blindly accepts.
    public static let disabled = SSLPinningConfiguration(
        uncheckedPublicKeyHashes: [],
        hosts: .only([]),
        chainValidation: .system
    )

    // MARK: Invariants (pure, testable without trapping)

    /// Checks the pin list against the invariants `init` enforces, without
    /// trapping. `nil` means the list is acceptable.
    ///
    /// Call this before `init` when the pins come from a remote or otherwise
    /// untrusted source, so a malformed payload becomes a handled error
    /// instead of a crash.
    public static func validatePins(_ pins: [String]) -> PinIssue? {
        guard pins.count >= 2 else { return .tooFew(count: pins.count) }
        for (index, pin) in pins.enumerated() {
            guard let data = Data(base64Encoded: pin) else { return .notBase64(index: index) }
            guard data.count == SHA256.byteCount else {
                return .wrongLength(index: index, bytes: data.count)
            }
        }
        return nil
    }

    /// The `DEBUG` gate for ``ChainValidation/unsafeSkipForDevelopment``.
    private static func gatedForDevelopment(_ requested: ChainValidation) -> ChainValidation {
        #if DEBUG
        return requested
        #else
        guard requested == .unsafeSkipForDevelopment else { return requested }
        assertionFailure(
            "SSLPinningConfiguration: .unsafeSkipForDevelopment used in a build without DEBUG. "
                + "The chain will be validated by the system (.system) instead."
        )
        return .system
        #endif
    }

    // MARK: Pure decision core (testable without network or SecTrust)

    /// Whether `host` requires pinning under this configuration.
    public func requiresPinning(host: String) -> Bool {
        guard !publicKeyHashes.isEmpty else { return false }
        switch hosts {
        case .all: return true
        case .only(let allowedHosts): return allowedHosts.contains(host)
        }
    }

    /// Pure 3-state decision. The autoclosures keep chain evaluation and key
    /// hashing lazy: neither runs when the host is not pinned, and the chain
    /// is not evaluated under `.unsafeSkipForDevelopment`.
    func decision(
        host: String,
        chainTrusted: @autoclosure () -> Bool,
        serverKeyHashes: @autoclosure () -> [String]
    ) -> PinningValidationResult {
        guard requiresPinning(host: host) else { return .notApplicable }
        if chainValidation == .system, !chainTrusted() { return .failed }
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
    /// Standard ASN.1 SPKI headers per key type/size (TrustKit's table plus
    /// RSA-3072, which TrustKit omits). Each header is verified against an
    /// openssl-generated key in `PinningTests`.
    private static let asn1Headers: [Header: [UInt8]] = [
        Header(keyType: kSecAttrKeyTypeRSA as String, keySizeInBits: 2048): [
            0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
            0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
        ],
        Header(keyType: kSecAttrKeyTypeRSA as String, keySizeInBits: 3072): [
            0x30, 0x82, 0x01, 0xa2, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
            0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x8f, 0x00
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
