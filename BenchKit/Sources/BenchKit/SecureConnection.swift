import Foundation

public enum SecureConnection {
    /// Whether a connection reached the other end but failed its TLS
    /// handshake or certificate check. Tailscale Serve fails the handshake
    /// when it has no certificate or doesn't know the name asked for.
    public static func isFailure(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return codes.contains(URLError.Code(rawValue: error.code))
    }

    private static let codes: Set<URLError.Code> = [
        .secureConnectionFailed,
        .serverCertificateHasBadDate,
        .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid,
        .clientCertificateRejected,
        .clientCertificateRequired,
    ]
}
