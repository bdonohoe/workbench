import BenchKit
import Foundation
import Security

/// Who this Mac is on the home network: a random id it advertises over
/// Bonjour, and the self-signed certificate phones pin. The private key
/// lives in the login keychain and never leaves it; the id and the
/// certificate are plain files, since neither is secret. Immutable, and
/// loaded off the main actor, since the keychain can be slow.
nonisolated final class LocalIdentity: @unchecked Sendable {
    /// 16 random bytes as lowercase hex. Never the computer's or the user's name.
    let macID: String
    /// SHA-256 of the certificate, which the pairing code carries.
    let fingerprint: String
    /// What the TLS listener serves.
    let identity: sec_identity_t

    private init(macID: String, fingerprint: String, identity: sec_identity_t) {
        self.macID = macID
        self.fingerprint = fingerprint
        self.identity = identity
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String, status: OSStatus? = nil) {
            let detail = status.map { SecCopyErrorMessageString($0, nil) as String? ?? "error \($0)" }
            errorDescription = detail.map { "\(message): \($0)" } ?? message
        }
    }

    /// What to do with what's saved.
    enum Plan: Equatable {
        /// The certificate and its key are both there and match.
        case use
        /// One is gone, or they don't match: a new key and certificate.
        case remake
        /// The keychain couldn't be read. Nothing is deleted; the next
        /// start tries again.
        case fail(OSStatus)
    }

    /// Remakes only when the key is really missing or doesn't go with the
    /// certificate. Any other keychain answer (locked, a denied prompt, a
    /// signing change) would otherwise throw away a key that's still
    /// there, and every paired phone's pin with it.
    static func plan(hasCertificate: Bool, keyStatus: OSStatus, keyMatches: Bool) -> Plan {
        switch keyStatus {
        case errSecSuccess: hasCertificate && keyMatches ? .use : .remake
        case errSecItemNotFound: .remake
        default: .fail(keyStatus)
        }
    }

    /// Loads what this Mac made before, making new parts only for what's
    /// missing or doesn't match: a certificate without its key (or for a
    /// different one) means a new key and certificate, but the id stays.
    /// A keychain it can't read right now is an error, and changes nothing.
    /// Secondary instances pass their own folder and label, so they never
    /// share the real Mac's id.
    static func loadOrMake(folder: URL, keychainLabel: String) throws -> LocalIdentity {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let macID = try loadOrMakeID(at: folder.appendingPathComponent("local-id"))
        let certURL = folder.appendingPathComponent("local-cert.der")

        let savedDER = try? Data(contentsOf: certURL)
        let certificate = savedDER.flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        let (keyStatus, savedKey) = privateKey(label: keychainLabel)
        let certificateKey = certificate.flatMap(publicKeyData)
        let keyMatches = certificateKey != nil && certificateKey == savedKey.flatMap(SecKeyCopyPublicKey).flatMap(externalData)
        switch plan(hasCertificate: certificate != nil, keyStatus: keyStatus, keyMatches: keyMatches) {
        case .use:
            guard let savedDER, let certificate, let identity = secIdentity(for: certificate) else {
                // The key is there and matches, so this is the keychain
                // again, not something to start over for.
                throw Failure("Couldn't pair the certificate with its key")
            }
            return LocalIdentity(macID: macID, fingerprint: CertificatePin.fingerprint(savedDER), identity: identity)
        case .fail(let status):
            throw Failure("Couldn't read the key from the keychain", status: status)
        case .remake:
            break
        }

        // Start over: whatever key was there belongs to a certificate
        // that's gone, or never had one.
        forget(keychainLabel: keychainLabel)
        let key = try makePrivateKey(label: keychainLabel)
        guard let publicKey = SecKeyCopyPublicKey(key).flatMap(externalData) else {
            throw Failure("Couldn't read the new key")
        }
        var serial: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &serial) { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let der = try SelfSignedCertificate.make(publicKey: publicKey, commonName: "Workbench", serial: serial >> 1,
                                                 notBefore: .now.addingTimeInterval(-86_400), years: 20) { tbs in
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) else {
                throw error?.takeRetainedValue() ?? Failure("Couldn't sign the certificate")
            }
            return signature as Data
        }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw Failure("Couldn't read the new certificate")
        }
        guard let identity = secIdentity(for: certificate) else {
            forget(keychainLabel: keychainLabel)
            throw Failure("Couldn't pair the certificate with its key")
        }
        try der.write(to: certURL, options: .atomic)
        return LocalIdentity(macID: macID, fingerprint: CertificatePin.fingerprint(der), identity: identity)
    }

    /// Deletes the keychain key under `keychainLabel`, if there is one.
    static func forget(keychainLabel: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassKey, kSecAttrLabel: keychainLabel]
        // The file keychain can hold several items with one label.
        var tries = 0
        while tries < 10, SecItemDelete(query as CFDictionary) == errSecSuccess { tries += 1 }
    }

    // MARK: Parts

    private static func loadOrMakeID(at url: URL) throws -> String {
        if let saved = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count == 32, saved.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            return saved
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure("Couldn't make an id for this Mac")
        }
        let id = bytes.map { String(format: "%02x", $0) }.joined()
        try Data(id.utf8).write(to: url, options: .atomic)
        return id
    }

    /// The key under `label`, with the keychain's answer: errSecItemNotFound
    /// when there's none, something else when it couldn't look.
    private static func privateKey(label: String) -> (OSStatus, SecKey?) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrLabel: label,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return (status, nil) }
        guard let item, CFGetTypeID(item) == SecKeyGetTypeID() else { return (errSecInvalidItemRef, nil) }
        return (errSecSuccess, (item as! SecKey))
    }

    private static func makePrivateKey(label: String) throws -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrLabel: label,
                kSecAttrIsExtractable: false,
            ] as [CFString: Any],
            kSecPublicKeyAttrs: [kSecAttrIsPermanent: false] as [CFString: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? Failure("Couldn't make a key")
        }
        return key
    }

    /// Finds the keychain key that goes with `certificate`, by its public key.
    private static func secIdentity(for certificate: SecCertificate) -> sec_identity_t? {
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess, let identity else { return nil }
        return sec_identity_create(identity)
    }

    private static func publicKeyData(of certificate: SecCertificate) -> Data? {
        SecCertificateCopyKey(certificate).flatMap(externalData)
    }

    private static func externalData(_ key: SecKey) -> Data? {
        SecKeyCopyExternalRepresentation(key, nil) as Data?
    }
}
