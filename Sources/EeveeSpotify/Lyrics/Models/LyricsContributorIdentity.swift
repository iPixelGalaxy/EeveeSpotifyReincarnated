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
        let username = nonEmpty(username)
        let displayName = nonEmpty(displayName)
        if let username, let displayName, username.lowercased() == displayName.lowercased() {
            return displayName
        }
        return username ?? displayName
    }

    func creditName(preserving suppliedName: String?) -> String {
        Self.preferredName(username: username, displayName: Self.nonEmpty(suppliedName) ?? displayName) ?? username
    }
}
