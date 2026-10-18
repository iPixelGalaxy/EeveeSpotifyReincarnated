import SwiftUI

@available(iOS 15.0, *)
struct KaraokeCreditsFooterView: View {
    let lyrics: KaraokeLyricsDto
    var showWriters = true
    var showDetails = true

    private var providerLabel: String? {
        nonEmpty(lyrics.providerName) ?? nonEmpty(lyrics.providerCode).map { _ in SpicyLyricsRepository.providerName }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func profile(_ label: String, name: String, link: String?, avatar: String?) -> some View {
        KaraokeContributorCredit(label: label, name: name, link: link, avatar: avatar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showWriters, !lyrics.songWriters.isEmpty {
                Text("\("lyrics_written_by".localized) \(lyrics.songWriters.joined(separator: ", "))")
                    .font(.system(size: 19.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showDetails {
                if let provider = providerLabel {
                    Text("\("lyrics_provided_by".localized): \(provider)")
                        .font(.system(size: 19.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let maker = nonEmpty(lyrics.makerName) {
                    profile("lyrics_made_by".localized, name: maker, link: lyrics.makerUrl, avatar: lyrics.makerAvatarUrl)
                }
                if let uploader = nonEmpty(lyrics.uploaderName) {
                    profile(nonEmpty(lyrics.makerName) == nil ? "lyrics_made_by".localized : "lyrics_uploaded_by".localized,
                            name: uploader, link: lyrics.uploaderUrl, avatar: lyrics.uploaderAvatarUrl)
                }
                if lyrics.hasExperimentalWordTiming {
                    Text("karaoke_experimental_timing".localized)
                        .font(.caption).foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}


@available(iOS 15.0, *)
private struct KaraokeContributorCredit: View {
    let label: String
    let name: String
    let link: String?
    let avatar: String?
    @State private var resolvedName: String?

    private func remoteURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value.hasPrefix("//") ? "https:" + value : value),
              url.scheme == "https" else { return nil }
        return url
    }

    var body: some View {
        let currentName = resolvedName ?? name
        let username = currentName.hasPrefix("@") ? currentName : "@" + currentName
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label).foregroundColor(.white.opacity(0.5))
            if let url = remoteURL(link) {
                Link(destination: url) { Text(username).fontWeight(.bold).underline() }
                    .foregroundColor(.white.opacity(0.65))
            } else {
                Text(username).fontWeight(.bold).foregroundColor(.white.opacity(0.65))
            }
            if let url = remoteURL(avatar) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                placeholder: { Color.clear }
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
                    .alignmentGuide(.firstTextBaseline) { $0.height * 0.78 }
                    .accessibilityLabel(Text(currentName))
            }
        }
        .font(.system(size: 19.5, weight: .semibold))
        .task(id: link) {
            let updated = await KaraokeProfileResolver.shared.username(profileURL: link)
            if !Task.isCancelled { resolvedName = updated }
        }
    }
}
