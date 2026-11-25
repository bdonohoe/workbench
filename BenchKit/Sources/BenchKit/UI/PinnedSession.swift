import Foundation
import Synchronization

/// URLSessions for the home network, which trust the Mac's own
/// certificate by its fingerprint and nothing else.
public enum PinnedSession {
    /// A server answered with a certificate other than the pinned one: the
    /// Mac made a new one, so the phone has to scan its code again.
    public struct Mismatch: Error, Equatable, Sendable {
        public init() {}
    }

    /// A session that accepts only a server whose certificate matches `pin`.
    /// Anything else is turned away before the hello goes out, and
    /// `onMismatch` hears about it.
    public static func make(pin: String, onMismatch: (@Sendable () -> Void)? = nil) -> URLSession {
        URLSession(configuration: .ephemeral, delegate: PinDelegate(pin: pin, onMismatch: onMismatch), delegateQueue: nil)
    }

    /// Answers the server-trust challenge by the pin alone. The hostname
    /// is an address on the home network, so it can't be checked.
    private final class PinDelegate: NSObject, URLSessionDelegate, Sendable {
        let pin: String
        let onMismatch: (@Sendable () -> Void)?
        init(pin: String, onMismatch: (@Sendable () -> Void)?) {
            self.pin = pin
            self.onMismatch = onMismatch
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
                return (.performDefaultHandling, nil)
            }
            guard let trust = challenge.protectionSpace.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
            guard CertificatePin.matches(trust, pin: pin) else {
                onMismatch?()
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        }
    }
}

/// Whether a pinned session has turned a certificate away since last asked.
final class PinMismatches: Sendable {
    private let seen = Mutex(false)

    func note() { seen.withLock { $0 = true } }

    /// True if one was turned away, and starts over.
    func take() -> Bool { seen.withLock { value in defer { value = false }; return value } }
}
