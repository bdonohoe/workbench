import CryptoKit
import Foundation

/// Sends Apple push notifications. With an APNs key from the developer
/// account the Mac talks to Apple itself. Without one it goes through
/// Workbench's push relay, which holds the key for the phone app and
/// passes each notification to Apple unchanged.
final class PushSender: @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    enum Environment: String, Codable, Sendable {
        case sandbox, production
        var host: String { self == .sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com" }
    }

    /// Where Workbench's relay lives.
    static let relayURL = URL(string: "https://workbench-push.vercel.app/api/push")!

    private enum Route {
        case direct(teamID: String, keyID: String, key: P256.Signing.PrivateKey)
        case relay(URL)
    }

    private let route: Route
    private let lock = NSLock()
    private var cachedToken: (value: String, issued: Date)?
    /// Which APNs environment each device token belongs to, once known.
    /// Builds from Xcode use the sandbox; TestFlight builds use production.
    private var environments: [String: Environment] = [:]

    init(teamID: String, keyID: String, pem: String) throws {
        do {
            route = .direct(teamID: teamID, keyID: keyID, key: try P256.Signing.PrivateKey(pemRepresentation: pem))
        } catch {
            throw Failure(message: "That isn't a valid APNs key file (.p8).")
        }
    }

    /// Sends through Workbench's relay instead of straight to Apple.
    init(relay: URL = PushSender.relayURL) {
        route = .relay(relay)
    }

    var usesRelay: Bool {
        if case .relay = route { return true }
        return false
    }

    /// Sends one notification. `pushType` is "alert" or "liveactivity";
    /// `topic` is the app's bundle id, with ".push-type.liveactivity"
    /// appended for a Live Activity.
    func send(payload: [String: Any], to deviceToken: String, topic: String, pushType: String,
              collapseID: String? = nil, priority: Int = 10) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let first = environment(for: deviceToken) ?? .sandbox
        do {
            try await post(data, to: deviceToken, environment: first, topic: topic, pushType: pushType, collapseID: collapseID, priority: priority)
            remember(first, for: deviceToken)
        } catch let failure as Failure where failure.message == "BadDeviceToken" && environment(for: deviceToken) == nil {
            // Wrong environment for this build of the app; try the other one.
            let other: Environment = first == .sandbox ? .production : .sandbox
            try await post(data, to: deviceToken, environment: other, topic: topic, pushType: pushType, collapseID: collapseID, priority: priority)
            remember(other, for: deviceToken)
        } catch let failure as Failure where failure.message == "ExpiredProviderToken" || failure.message == "InvalidProviderToken" {
            // The signed token went stale (the clock moved, say): make a new
            // one and try once more.
            forgetToken()
            try await post(data, to: deviceToken, environment: first, topic: topic, pushType: pushType, collapseID: collapseID, priority: priority)
        }
    }

    private func forgetToken() {
        lock.lock(); defer { lock.unlock() }
        cachedToken = nil
    }

    private func post(_ body: Data, to deviceToken: String, environment: Environment, topic: String, pushType: String,
                      collapseID: String?, priority: Int) async throws {
        var request: URLRequest
        switch route {
        case .direct(let teamID, let keyID, let key):
            request = URLRequest(url: URL(string: "https://\(environment.host)/3/device/\(deviceToken)")!)
            request.httpBody = body
            request.setValue("bearer \(try jwt(teamID: teamID, keyID: keyID, key: key))", forHTTPHeaderField: "authorization")
            request.setValue(topic, forHTTPHeaderField: "apns-topic")
            request.setValue(pushType, forHTTPHeaderField: "apns-push-type")
            request.setValue("\(priority)", forHTTPHeaderField: "apns-priority")
            if let collapseID { request.setValue(String(collapseID.prefix(64)), forHTTPHeaderField: "apns-collapse-id") }
        case .relay(let url):
            // The relay answers with Apple's own status and reason.
            request = URLRequest(url: url)
            var envelope: [String: Any] = [
                "environment": environment.rawValue, "token": deviceToken, "topic": topic, "pushType": pushType,
                "priority": priority, "payload": try JSONSerialization.jsonObject(with: body),
            ]
            if let collapseID { envelope["collapseID"] = String(collapseID.prefix(64)) }
            request.httpBody = try JSONSerialization.data(withJSONObject: envelope)
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "No response from Apple.") }
        guard http.statusCode == 200 else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
            throw Failure(message: reason ?? "Apple answered \(http.statusCode).")
        }
    }

    private func environment(for token: String) -> Environment? {
        lock.lock(); defer { lock.unlock() }
        return environments[token]
    }

    private func remember(_ environment: Environment, for token: String) {
        lock.lock(); defer { lock.unlock() }
        environments[token] = environment
    }

    /// The signed token Apple wants in every request. Good for an hour;
    /// made fresh after 50 minutes.
    private func jwt(teamID: String, keyID: String, key: P256.Signing.PrivateKey) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let cachedToken, Date().timeIntervalSince(cachedToken.issued) < 50 * 60 { return cachedToken.value }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID])
        let claims = try JSONSerialization.data(withJSONObject: ["iss": teamID, "iat": Int(Date().timeIntervalSince1970)])
        let signingInput = Self.base64url(header) + "." + Self.base64url(claims)
        let signature = try key.signature(for: Data(signingInput.utf8))
        let token = signingInput + "." + Self.base64url(signature.rawRepresentation)
        cachedToken = (token, Date())
        return token
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
