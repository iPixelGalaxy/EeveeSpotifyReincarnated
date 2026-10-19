import Foundation

struct LyricsContributorIdentity: Sendable {
    let username: String
    let displayName: String?

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    // Match Spicy's credits: preserve display-name casing only when it identifies the same username.
    static func preferredName(username: String?, displayName: String?) -> String? {
        guard let username = nonEmpty(username) else { return nil }
        let displayName = nonEmpty(displayName)
        if let displayName, username.lowercased() == displayName.lowercased() {
            return displayName
        }
        return username
    }

    func creditName(preserving suppliedName: String?) -> String {
        if let suppliedName = Self.nonEmpty(suppliedName), suppliedName.lowercased() == username.lowercased() {
            return suppliedName
        }
        return Self.preferredName(username: username, displayName: displayName) ?? username
    }
}
