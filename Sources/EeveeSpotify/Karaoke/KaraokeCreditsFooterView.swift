import SwiftUI

@available(iOS 15.0, *)
struct KaraokeCreditsFooterView: View {
    let lyrics: KaraokeLyricsDto
    var showWriters = true
    var showDetails = true
    var unfaded = false
    var bottomPadding: CGFloat = 12
    @State private var resolvedCredits: ResolvedCredits?

    private struct ContributorKey: Hashable {
        let makerName: String?
        let makerURL: String?
        let uploaderName: String?
        let uploaderURL: String?
        let showDetails: Bool
    }

    private struct ResolvedCredits {
        let key: ContributorKey
        let maker: String?
        let uploader: String?
    }

    private var contributorKey: ContributorKey {
        ContributorKey(makerName: nonEmpty(lyrics.makerName) ?? KaraokeProfileResolver.userID(profileURL: lyrics.makerUrl),
                       makerURL: lyrics.makerUrl,
                       uploaderName: nonEmpty(lyrics.uploaderName) ?? KaraokeProfileResolver.userID(profileURL: lyrics.uploaderUrl),
                       uploaderURL: lyrics.uploaderUrl, showDetails: showDetails)
    }

    private var creditsReady: Bool {
        !showDetails || (contributorKey.makerName == nil && contributorKey.uploaderName == nil)
            || resolvedCredits?.key == contributorKey
    }

    private func resolveName(_ name: String?, link: String?) async -> String? {
        guard let name else { return nil }
        let profile = await KaraokeProfileResolver.shared.identity(profileURL: link)
        // Lyrics metadata can put a display name in "username". Never restore it on lookup failure.
        return profile?.creditName(preserving: name) ?? KaraokeProfileResolver.userID(profileURL: link)
    }

    private var providerLabel: String? {
        nonEmpty(lyrics.providerName) ?? nonEmpty(lyrics.providerCode).map { _ in SpicyLyricsRepository.providerName }
    }

    private var experimentSuffix: String {
        let extra = providerLabel == "Apple Music" && lyrics.timingExperiments.contains(.extraSplits)
        return (extra ? "karaoke_extra_splits_suffix".localized : "")
            + (lyrics.timingExperiments.contains(.automaticSplitting) ? "karaoke_automatic_splitting_suffix".localized : "")
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
                    .foregroundColor(.white.opacity(unfaded ? 1 : 0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showDetails {
                if let provider = providerLabel {
                    Text("\("lyrics_provided_by".localized): \(provider)\(experimentSuffix)")
                        .font(.system(size: 19.5, weight: .semibold))
                        .foregroundColor(.white.opacity(unfaded ? 1 : 0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let maker = (resolvedCredits?.key == contributorKey ? resolvedCredits?.maker : contributorKey.makerName) {
                    profile("lyrics_made_by".localized, name: maker, link: lyrics.makerUrl, avatar: lyrics.makerAvatarUrl)
                }
                if let uploader = (resolvedCredits?.key == contributorKey ? resolvedCredits?.uploader : contributorKey.uploaderName) {
                    profile(contributorKey.makerName == nil ? "lyrics_made_by".localized : "lyrics_uploaded_by".localized,
                            name: uploader, link: lyrics.uploaderUrl, avatar: lyrics.uploaderAvatarUrl)
                }
                if lyrics.timingExperiments.contains(.spaceGravity) {
                    Text("karaoke_space_gravity_timing_notice".localized)
                        .font(.caption).foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, bottomPadding)
        .opacity(creditsReady ? 1 : 0)
        .allowsHitTesting(creditsReady)
        .accessibilityHidden(!creditsReady)
        .task(id: contributorKey) {
            let key = contributorKey
            guard key.showDetails else { return }
            async let maker = resolveName(key.makerName, link: key.makerURL)
            async let uploader = resolveName(key.uploaderName, link: key.uploaderURL)
            let names = await (maker, uploader)
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)) {
                resolvedCredits = ResolvedCredits(key: key, maker: names.0, uploader: names.1)
            }
        }
    }
}


@available(iOS 15.0, *)
private struct KaraokeContributorCredit: View {
    let label: String
    let name: String
    let link: String?
    let avatar: String?

    private func remoteURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value.hasPrefix("//") ? "https:" + value : value),
              url.scheme == "https" else { return nil }
        return url
    }

    var body: some View {
        let currentName = name
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
    }
}
