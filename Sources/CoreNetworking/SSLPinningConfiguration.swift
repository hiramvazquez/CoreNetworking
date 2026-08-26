import Foundation
import Security

/// Configuration for SSL Certificate Pinning using public keys.
///
/// SSL Pinning prevents man-in-the-middle attacks by validating that the server's
/// certificate matches one of your trusted public keys.
///
/// ## Security Benefits
/// - Protects against compromised Certificate Authorities
/// - Prevents man-in-the-middle attacks
/// - Ensures you're connecting to the expected server
///
/// ## Example - Pin Specific Hosts
/// ```swift
/// let pinning = SSLPinningConfiguration(
///     publicKeys: [
///         "base64-encoded-public-key-1",
///         "base64-encoded-public-key-2"
///     ],
///     pinnedHosts: ["api.myapp.com", "cdn.myapp.com"]
/// )
///
/// let service = APIService(sslPinning: pinning)
/// ```
///
/// ## Example - Pin All Hosts
/// ```swift
/// let pinning = SSLPinningConfiguration(
///     publicKeys: ["base64-encoded-public-key"],
///     pinnedHosts: nil  // Apply to all hosts
/// )
/// ```
///
/// ## How to Extract Public Keys
///
/// ### From Certificate File (.cer, .crt)
/// ```bash
/// # 1. Extract public key from certificate
/// openssl x509 -in certificate.crt -pubkey -noout > pubkey.pem
///
/// # 2. Convert to DER format
/// openssl rsa -pubin -in pubkey.pem -outform DER -out pubkey.der
///
/// # 3. Get base64 hash (SHA256)
/// openssl dgst -sha256 -binary pubkey.der | openssl base64
/// ```
///
/// ### From Running Server
/// ```bash
/// # 1. Get certificate from server
/// openssl s_client -connect api.example.com:443 -showcerts < /dev/null | \
///     openssl x509 -outform PEM > server.pem
///
/// # 2. Extract public key
/// openssl x509 -in server.pem -pubkey -noout > pubkey.pem
///
/// # 3. Convert to DER and hash
/// openssl rsa -pubin -in pubkey.pem -outform DER -out pubkey.der
/// openssl dgst -sha256 -binary pubkey.der | openssl base64
/// ```
public struct SSLPinningConfiguration: Sendable {
    /// Array of base64-encoded SHA256 hashes of trusted public keys.
    ///
    /// These are compared against the server's certificate public key.
    /// At least one must match for the connection to succeed.
    public let publicKeyHashes: [String]

    /// Optional list of hosts to apply pinning to.
    ///
    /// - If `nil`: Pinning applies to ALL hosts
    /// - If empty: No pinning is performed
    /// - If contains hosts: Only those hosts are pinned
    ///
    /// ## Example
    /// ```swift
    /// pinnedHosts: ["api.myapp.com", "cdn.myapp.com"]
    /// ```
    public let pinnedHosts: Set<String>?

    /// Whether to validate the certificate trust chain before checking pins.
    ///
    /// - `true`: Validates trust chain first, then checks pins (recommended)
    /// - `false`: Only checks pins, skips trust chain validation (not recommended)
    ///
    /// **Recommendation**: Keep this `true` for production. Only set to `false`
    /// if you're using self-signed certificates in development.
    public let validateCertificateChain: Bool

    /// Creates an SSL Pinning configuration.
    ///
    /// - Parameters:
    ///   - publicKeyHashes: Base64-encoded SHA256 hashes of trusted public keys
    ///   - pinnedHosts: Optional set of hosts to apply pinning (nil = all hosts)
    ///   - validateCertificateChain: Whether to validate trust chain (default: true)
    public init(
        publicKeyHashes: [String],
        pinnedHosts: Set<String>? = nil,
        validateCertificateChain: Bool = true
    ) {
        self.publicKeyHashes = publicKeyHashes
        self.pinnedHosts = pinnedHosts
        self.validateCertificateChain = validateCertificateChain
    }

    /// Validates a server trust challenge against pinned public keys.
    ///
    /// - Parameters:
    ///   - serverTrust: The server trust to validate
    ///   - host: The host being connected to
    /// - Returns: `true` if validation succeeds, `false` otherwise
    public func validate(serverTrust: SecTrust, forHost host: String) -> Bool {
        // Check if this host should be pinned
        if let pinnedHosts = pinnedHosts {
            guard pinnedHosts.contains(host) else {
                // Host not in pinned list, allow connection
                return true
            }
        }

        // Validate certificate chain first (if enabled)
        if validateCertificateChain {
            var error: CFError?
            guard SecTrustEvaluateWithError(serverTrust, &error) else {
                #if DEBUG
                print("❌ [SSL] Certificate chain validation failed: \(error?.localizedDescription ?? "unknown")")
                #endif
                return false
            }
        }

        // Extract server's public keys
        let serverPublicKeys = extractPublicKeys(from: serverTrust)

        // Check if any server public key matches our pinned keys
        for serverKey in serverPublicKeys {
            let serverKeyHash = sha256Hash(of: serverKey)
            let serverKeyHashBase64 = serverKeyHash.base64EncodedString()

            if publicKeyHashes.contains(serverKeyHashBase64) {
                #if DEBUG
                print("✅ [SSL] Public key matched for host: \(host)")
                #endif
                return true
            }
        }

        #if DEBUG
        print("❌ [SSL] No matching public key found for host: \(host)")
        print("   Server keys: \(serverPublicKeys.map { sha256Hash(of: $0).base64EncodedString() })")
        print("   Expected keys: \(publicKeyHashes)")
        #endif

        return false
    }

    // MARK: - Private Helpers

    /// Extracts public keys from a server trust object.
    private func extractPublicKeys(from serverTrust: SecTrust) -> [SecKey] {
        var publicKeys: [SecKey] = []

        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // iOS 15+
        if #available(iOS 15.0, tvOS 15.0, watchOS 8.0, *) {
            if let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] {
                for certificate in certificates {
                    if let publicKey = SecCertificateCopyKey(certificate) {
                        publicKeys.append(publicKey)
                    }
                }
            }
        } else {
            // iOS 14 and earlier
            let certificateCount = SecTrustGetCertificateCount(serverTrust)
            for i in 0..<certificateCount {
                if let certificate = SecTrustGetCertificateAtIndex(serverTrust, i),
                   let publicKey = SecCertificateCopyKey(certificate) {
                    publicKeys.append(publicKey)
                }
            }
        }
        #else
        // macOS
        let certificateCount = SecTrustGetCertificateCount(serverTrust)
        for i in 0..<certificateCount {
            if let certificate = SecTrustGetCertificateAtIndex(serverTrust, i),
               let publicKey = SecCertificateCopyKey(certificate) {
                publicKeys.append(publicKey)
            }
        }
        #endif

        return publicKeys
    }

    /// Computes SHA256 hash of a public key.
    private func sha256Hash(of publicKey: SecKey) -> Data {
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return Data()
        }

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        publicKeyData.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(publicKeyData.count), &hash)
        }

        return Data(hash)
    }
}

// MARK: - CommonCrypto Import

#if canImport(CommonCrypto)
import CommonCrypto
#else
// For platforms without CommonCrypto, use CryptoKit
import CryptoKit

extension SSLPinningConfiguration {
    private func sha256Hash(of publicKey: SecKey) -> Data {
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return Data()
        }

        let hash = SHA256.hash(data: publicKeyData)
        return Data(hash)
    }
}
#endif

// MARK: - Disabled Pinning

public extension SSLPinningConfiguration {
    /// Disabled SSL pinning (no validation performed).
    ///
    /// **Warning**: Only use this for development/testing.
    /// Never disable SSL pinning in production builds.
    static let disabled = SSLPinningConfiguration(
        publicKeyHashes: [],
        pinnedHosts: Set(),
        validateCertificateChain: true
    )
}

// MARK: - Equatable

extension SSLPinningConfiguration: Equatable {
    public static func == (lhs: SSLPinningConfiguration, rhs: SSLPinningConfiguration) -> Bool {
        lhs.publicKeyHashes == rhs.publicKeyHashes &&
        lhs.pinnedHosts == rhs.pinnedHosts &&
        lhs.validateCertificateChain == rhs.validateCertificateChain
    }
}
