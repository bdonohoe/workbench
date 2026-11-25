import CryptoKit
import Foundation
import Security
import Testing
@testable import BenchKit

struct SelfSignedCertificateTests {
    private func make(_ key: P256.Signing.PrivateKey = .init(), serial: UInt64 = 1) throws -> Data {
        try SelfSignedCertificate.make(key: key, commonName: "Workbench", serial: serial, notBefore: Date(timeIntervalSince1970: 1_700_000_000), years: 10)
    }

    // Reads one DER element at `at`: its full bytes and where its content sits.
    private func element(_ data: Data, at start: Int) -> (full: Data, content: Range<Int>) {
        let bytes = [UInt8](data)
        var index = start + 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7f
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        return (Data(bytes[start..<index + length]), index..<index + length)
    }

    @Test func makesACertificateSecurityAccepts() throws {
        let key = P256.Signing.PrivateKey()
        let der = try make(key)
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let publicKey = try #require(SecCertificateCopyKey(certificate))
        let external = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        #expect(external == key.publicKey.x963Representation)
    }

    @Test func signatureVerifies() throws {
        let key = P256.Signing.PrivateKey()
        let der = try make(key)
        let outer = element(der, at: 0)
        let tbs = element(der, at: outer.content.lowerBound)
        let algorithm = element(der, at: outer.content.lowerBound + tbs.full.count)
        let bits = element(der, at: outer.content.lowerBound + tbs.full.count + algorithm.full.count)
        // Skip the unused-bits byte at the start of the BIT STRING.
        let signature = try P256.Signing.ECDSASignature(derRepresentation: der[(bits.content.lowerBound + 1)..<bits.content.upperBound])
        #expect(key.publicKey.isValidSignature(signature, for: tbs.full))
    }

    @Test func fingerprintIsStable() throws {
        let a = try make(serial: 1)
        let b = try make(serial: 2)
        let first = CertificatePin.fingerprint(a)
        #expect(first == CertificatePin.fingerprint(a))
        #expect(first.count == 64)
        #expect(first == first.lowercased())
        #expect(first.allSatisfy { $0.isHexDigit })
        #expect(first != CertificatePin.fingerprint(b))
    }

    @Test func pinMatchesOnlyItsCertificate() throws {
        let a = try make()
        let b = try make()
        let certificate = try #require(SecCertificateCreateWithData(nil, a as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let made = try #require(trust)
        #expect(CertificatePin.matches(made, pin: CertificatePin.fingerprint(a)))
        #expect(!CertificatePin.matches(made, pin: CertificatePin.fingerprint(b)))
    }

    /// basicConstraints with cA left at its DEFAULT of false: DER says
    /// leave it out, so the extension's value is an empty SEQUENCE.
    @Test func basicConstraintsOmitsTheDefault() throws {
        let der = try make()
        let oid = Data([0x06, 0x03, 0x55, 0x1D, 0x13])
        let at = try #require(der.range(of: oid))
        // OID, then OCTET STRING { SEQUENCE {} }.
        #expect(der[at.upperBound..<at.upperBound + 4] == Data([0x04, 0x02, 0x30, 0x00]))
    }
}
