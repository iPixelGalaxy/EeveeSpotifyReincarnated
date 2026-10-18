import SwiftUI

@available(iOS 15.0, *)
struct KaraokeCreditsFooterView: View {
    let lyrics: KaraokeLyricsDto

    private var providerLabel: String? {
        nonEmpty(lyrics.providerName) ?? nonEmpty(lyrics.providerCode).map { _ in SpicyLyricsRepository.providerName }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func remoteURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value.hasPrefix("//") ? "https:" + value : value),
              url.scheme == "https" else { return nil }
        return url
    }

    private func profile(_ label: String, name: String, link: String?, avatar: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
            HStack(spacing: 8) {
                let username = name.hasPrefix("@") ? name : "@" + name
                if let url = remoteURL(link) {
                    Link(username, destination: url).foregroundColor(.white.opacity(0.9))
                } else {
                    Text(username).foregroundColor(.white.opacity(0.9))
                }
                if let url = remoteURL(avatar) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle.fill").foregroundColor(.white.opacity(0.3))
                    }
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                    .accessibilityLabel(Text(name))
                }
            }
            .font(.system(size: 15, weight: .semibold))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !lyrics.songWriters.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("lyrics_written_by".localized)
                        .font(.system(size: 14, weight: .semibold))
                    Text(lyrics.songWriters.joined(separator: ", "))
                        .font(.system(size: 15))
                }
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            }
            if let provider = providerLabel {
                HStack(spacing: 8) {
                    if provider.localizedCaseInsensitiveContains("spicy") {
                        Image(uiImage: SpicyLyricsBrand.image(size: 20)).accessibilityHidden(true)
                    }
                    Text("\("lyrics_provided_by".localized) \(provider)")
                }
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
            }
            if let maker = nonEmpty(lyrics.makerName) {
                profile("lyrics_made_by".localized, name: maker, link: lyrics.makerUrl, avatar: lyrics.makerAvatarUrl)
            }
            if let uploader = nonEmpty(lyrics.uploaderName) {
                profile(nonEmpty(lyrics.makerName) == nil ? "lyrics_made_by".localized : "lyrics_uploaded_by".localized,
                        name: uploader, link: lyrics.uploaderUrl, avatar: lyrics.uploaderAvatarUrl)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }
}
