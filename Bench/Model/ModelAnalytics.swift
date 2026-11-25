import Foundation

/// What analytics says about a Claude model: only its family, from a fixed
/// list, and a version number like "5.5" when there is one. Model names
/// come from Claude Code, and a custom one (a Bedrock ARN, say) could
/// carry an account ID, so nothing else from the name is sent.
enum ModelAnalytics {
    /// For `claude_model_used`, from a name like "Opus 5.5".
    static func properties(model: String) -> [String: Any] {
        let family = ModelFamily(model: model)
        var properties: [String: Any] = ["family": family.analyticsName]
        if family != .other, let version = version(of: model) { properties["version"] = version }
        return properties
    }

    /// For `model_switched`: the session's model before, like "Opus 5.5",
    /// and what `/model` asked for, like "fable".
    static func switchProperties(from: String?, to: String, fromPhone: Bool) -> [String: Any] {
        ["from": from.map { ModelFamily(model: $0).analyticsName } ?? "unknown",
         "to": ModelFamily(model: to).analyticsName,
         "from_phone": fromPhone]
    }

    /// "5.5" from "Opus 5.5": digits and dots only, or nothing.
    private static func version(of model: String) -> String? {
        guard let last = model.split(separator: " ").last, last.first?.isNumber == true,
              last.allSatisfy({ $0.isNumber || $0 == "." }), last.count <= 8 else { return nil }
        return String(last)
    }
}

extension ModelFamily {
    var analyticsName: String { name.lowercased() }
}
