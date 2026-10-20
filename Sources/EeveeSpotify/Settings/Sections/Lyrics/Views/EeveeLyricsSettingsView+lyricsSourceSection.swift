import SwiftUI

extension EeveeLyricsSettingsView {
    private static let spicyTemplateURL = "https://developers.spicylyrics.org/catalog/eeveespotifyreincarnated"

    private func lyricsSourceFooterText() -> String {
        var text = "lyrics_source_description".localized

        text.append("\n\n")
        text.append("spicylyrics_description".localized)
        text.append("\n\n" + "lyrics_plugin_sources_description".localized)

        text.append("\n\n")
        text.append("petitlyrics_description".localized)

        text.append("\n\n")
        text.append("lyrics_additional_info".localized)

        return text
    }

    @ViewBuilder private func lyricsSourceFooter() -> some View {
        let text = lyricsSourceFooterText()

        if #available(iOS 15.0, *) {
            Text(spicyLinkedAttributedString(text))
        } else {
            Text(text)
        }
    }

    // The link text is localized together with spicylyrics_description, so find it by its own key.
    @available(iOS 15.0, *)
    private func spicyLinkedAttributedString(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)

        if let range = attributed.range(of: "spicylyrics_template_link".localized),
           let url = URL(string: Self.spicyTemplateURL) {
            attributed[range].link = url
        }

        return attributed
    }
    
    @ViewBuilder func lyricsSourceSection() -> some View {
        Section {
            Toggle(
                "do_not_replace_lyrics".localized,
                isOn: Binding<Bool>(
                    get: { viewModel.lyricsSource == .notReplaced },
                    set: {
                        viewModel.lyricsSource = $0
                            ? .notReplaced
                            : LyricsSource.defaultSource
                    }
                )
            )
        } footer: {
            Text("restart_is_required_description".localized)
        }
        
        if viewModel.lyricsSource.isReplacingLyrics {
            Section(footer: lyricsSourceFooter()) {
                NavigationLink(destination: lyricsSourcesMenu()) {
                    Text("lyrics_sources_manage".localized)
                }

            }
        }
    }
    
    private func lyricsSourcesMenu() -> some View {
        List {
            Section(footer: Text("lyrics_sources_order_hint".localized)) {
                ForEach(viewModel.lyricsSources.order, id: \.self) { source in
                    Toggle(source.description, isOn: Binding(
                        get: { !viewModel.lyricsSources.disabled.contains(source) },
                        set: { enabled in
                            if enabled { viewModel.lyricsSources.disabled.removeAll { $0 == source } }
                            else if !viewModel.lyricsSources.disabled.contains(source) { viewModel.lyricsSources.disabled.append(source) }
                        }
                    ))
                }
                .onMove { indices, destination in viewModel.lyricsSources.order.move(fromOffsets: indices, toOffset: destination) }
            }
            Section(header: Text("lyrics_sources_rating".localized), footer: Text("lyrics_sources_rating_hint".localized)) {
                HStack { Text("lyrics_sources_word".localized); Spacer(); Text("3") }
                HStack { Text("lyrics_sources_line".localized); Spacer(); Text("2") }
                HStack { Text("lyrics_sources_plain".localized); Spacer(); Text("1") }
                Toggle("lyrics_sources_apple_quality".localized, isOn: $viewModel.lyricsSources.prioritizeAppleMusic)
            }
            Section {
                if viewModel.lyricsSources.enabled.contains(.spicylyrics) || viewModel.lyricsSources.enabled.contains(.appleMusic) { spicyLyricsApiKeyField() }
                if viewModel.lyricsSources.enabled.contains(.musixmatch) { musixmatchTokenField() }
                if viewModel.lyricsSources.enabled.contains(.lrclib) { lrclibURLField() }
                Button("lyrics_sources_reset".localized) { viewModel.lyricsSources = LyricsSourcePreferences() }
            }
        }
        .navigationTitle("lyrics_sources_manage".localized)
        .toolbar { EditButton() }
    }

    @ViewBuilder private func musixmatchTokenField() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("musixmatch_user_token".localized)
            
            TextField("user_token_placeholder".localized, text: $viewModel.musixmatchToken)
                .foregroundColor(.gray)
        }
        .icon(
            "exclamationmark.circle",
            color: .red,
            when: Binding<Bool>(
                get: { !viewModel.isMusixmatchTokenValid },
                set: { _ in }
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        
        Button {
            viewModel.requestAnonymousMusixmatchToken()
        } label: {
            if viewModel.isRequestingMusixmatchToken {
                HStack {
                    ProgressView()
                    Text("request_anonymous_token".localized)
                        .padding(.leading, 8)
                }
            } else {
                Text("request_anonymous_token".localized)
            }
        }
        .disabled(viewModel.isRequestingMusixmatchToken)
    }
    
    @ViewBuilder private func spicyLyricsApiKeyField() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("spicylyrics_api_key".localized)

            TextField("spicylyrics_api_key_placeholder".localized, text: $spicyLyricsApiKey)
                .foregroundColor(.gray)
                .autocapitalization(.none)
                .disableAutocorrection(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func lrclibURLField() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("lrclib_api".localized)
            
            TextField(LrclibLyricsRepository.originalApiUrl, text: $viewModel.lyricsOptions.lrclibUrl)
                .foregroundColor(.gray)
        }
        .icon(
            "exclamationmark.circle",
            color: .red,
            when: Binding<Bool>(
                get: {
                    viewModel.lrclibURLState == .invalidURL
                    || viewModel.lrclibURLState == .unreachableURL
                },
                set: { _ in }
            )
        )
        .icon(
            "checkmark.seal",
            color: .green,
            when: Binding<Bool>(
                get: { viewModel.lrclibURLState == .originalURL },
                set: { _ in }
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
