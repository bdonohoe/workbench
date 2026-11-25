import CryptoKit
import Foundation
import Security

/// Pins a server by the SHA-256 fingerprint of its leaf certificate.
public enum CertificatePin {
    /// Lowercase hex SHA-256 of the certificate's DER bytes.
    public static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// True when the leaf certificate matches the pin. The hostname and the chain are ignored.
    public static func matches(_ trust: SecTrust, pin: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return false }
        return fingerprint(SecCertificateCopyData(leaf) as Data) == pin.lowercased()
    }
}
