import SwiftUI

struct EeveeLyricsSettingsView: View {
    @StateObject var viewModel = EeveeLyricsSettingsViewModel()
    @State private var karaokeOptions: KaraokeOptions = UserDefaults.karaokeOptions
    @ObservedObject private var lyricFont = KaraokeFont.shared
    @ObservedObject private var motion = KaraokeSpaceMotion.shared
    @State private var fontURLDraft = UserDefaults.karaokeOptions.customFontURL
    @State private var shareMotion = false
    @State var spicyLyricsApiKey: String = UserDefaults.spicyLyricsApiKey

    var body: some View {
        List {
            lyricsSourceSection()

            if viewModel.lyricsSource != .notReplaced {
                if viewModel.lyricsSource != .genius {
                    geniusFallbackSection()
                }
                
                hideOnErrorSection()
                romanizedLyricsSection()
                
                if viewModel.lyricsSource == .musixmatch {
                    musixmatchLanguageSection()
                }

                if viewModel.lyricsSource.supportsCustomLyricsView {
                    karaokeAppearanceSection()
                    SettingsResetSection(visible: karaokeOptions != KaraokeOptions()) { karaokeOptions = KaraokeOptions() }
                }
            }

            SpacerView()
        }
        .onReceive(viewModel.musixmatchTokenInputAlertPublisher) { showAnonymousTokenOption in
            showMusixmatchTokenAlert(UserDefaults.lyricsSource, showAnonymousTokenOption)
        }
        .eeveeSettingsStyle()
        .disabled(viewModel.isRequestingMusixmatchToken)
        .animation(.default, value: viewModel.animationValues)
        .onChange(of: karaokeOptions) {
            UserDefaults.karaokeOptions = $0
            lyricFont.configure($0)
            NotificationCenter.default.post(name: .eeveeKaraokeOptionsChanged, object: nil)
        }
        .onChange(of: karaokeOptions.customFontURL) { fontURLDraft = $0 }
        .sheet(isPresented: $shareMotion) {
            if let url = motion.sampleURL { KaraokeMotionShareSheet(url: url) }
        }
        .onChange(of: spicyLyricsApiKey) { UserDefaults.spicyLyricsApiKey = $0 }
    }

    @ViewBuilder private func gravityControls() -> some View {
        Toggle("karaoke_space_gravity".localized, isOn: $karaokeOptions.spaceGravityMode)
        if karaokeOptions.spaceGravityMode {
            Text("karaoke_space_gravity_help".localized).font(.caption).foregroundColor(.gray)
        }
        motionSampleControls()
    }

    @ViewBuilder private func wordSplittingControls() -> some View {
        Toggle("karaoke_word_splitting".localized, isOn: Binding(
            get: { karaokeOptions.wordSplittingEnabled },
            set: { karaokeOptions.experimentalWordSplitting = $0 }
        )).disabled(karaokeOptions.spaceGravityMode)
        if karaokeOptions.spaceGravityMode {
            Text("karaoke_word_splitting_gravity".localized).font(.caption).foregroundColor(.gray)
        } else if karaokeOptions.experimentalWordSplitting {
            Text("karaoke_word_splitting_help".localized).font(.caption).foregroundColor(.gray)
        }
    }

    @ViewBuilder private func motionSampleControls() -> some View {
        if karaokeOptions.spaceGravityMode || motion.recording || motion.sampleURL != nil {
            Button(motion.recording ? "karaoke_motion_recording".localized : "karaoke_motion_record".localized) {
                motion.recordSample()
            }.disabled(motion.recording)
            Text("karaoke_motion_help".localized).font(.caption).foregroundColor(.gray)
            if !motion.recording, !motion.recordingStatus.isEmpty {
                Text(motion.recordingStatus).font(.caption).foregroundColor(.gray)
            }
            if motion.sampleURL != nil {
                Button("karaoke_motion_share".localized) { shareMotion = true }
            }
        }
    }

    @ViewBuilder private func customFontControls() -> some View {
        Toggle("karaoke_custom_font".localized, isOn: $karaokeOptions.customFontEnabled)
        if karaokeOptions.customFontEnabled {
            VStack(alignment: .leading, spacing: 8) {
                TextField("https://example.com/font.ttf", text: $fontURLDraft)
                    .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                    .accessibilityLabel("karaoke_font_url".localized)
                HStack {
                    Button("karaoke_font_load".localized) {
                        let url = fontURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if karaokeOptions.customFontURL == url { lyricFont.configure(karaokeOptions, force: true) }
                        else { karaokeOptions.customFontURL = url }
                    }.disabled(fontURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if lyricFont.loading { ProgressView() }
                }
                Text("karaoke_font_help".localized).font(.caption).foregroundColor(.gray)
                if !lyricFont.status.isEmpty {
                    Text(lyricFont.status).font(.caption).foregroundColor(lyricFont.failed ? .red : .gray)
                }
            }
        }
    }

    @ViewBuilder private func pinnedFooterControls() -> some View {
        Picker("karaoke_pin_footer".localized, selection: $karaokeOptions.pinnedFooterMode) {
            ForEach(KaraokePinnedFooterMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }.disabled(karaokeOptions.spaceGravityMode)
        if karaokeOptions.spaceGravityMode {
            Text("karaoke_footer_gravity".localized).font(.caption).foregroundColor(.gray)
        } else if karaokeOptions.pinnedFooterMode == .noWriters {
            Text("karaoke_footer_writers_scroll".localized).font(.caption).foregroundColor(.gray)
        }
    }

    @ViewBuilder private func karaokeAppearanceSection() -> some View {
        Section {
            Toggle(
                "karaoke_enabled".localized,
                isOn: $karaokeOptions.enabled
            )

            Toggle("allow_screen_recording".localized, isOn: $karaokeOptions.allowScreenRecording)

            if karaokeOptions.enabled {
                gravityControls()
                wordSplittingControls()
                Toggle("karaoke_landscape_canvas".localized, isOn: $karaokeOptions.landscapeCanvas)
                Text("karaoke_landscape_canvas_detail".localized).font(.caption).foregroundColor(.gray)
                Picker("karaoke_release_year".localized, selection: $karaokeOptions.releaseYearPosition) {
                    ForEach(KaraokeReleaseYearPosition.allCases, id: \.self) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                Toggle("karaoke_smooth_scrolling".localized, isOn: $karaokeOptions.smoothScrolling)
                Toggle("karaoke_early_scrolling".localized, isOn: $karaokeOptions.earlyScrolling)
                if karaokeOptions.earlyScrolling {
                    HStack {
                        Text("karaoke_scroll_lead".localized)
                        Spacer()
                        Text(String(format: "%.0f ms", karaokeOptions.scrollLeadMs)).font(.system(size: 14, design: .monospaced))
                    }
                    Slider(value: $karaokeOptions.scrollLeadMs, in: 0...800, step: 10)
                    Text("karaoke_early_scrolling_detail".localized).font(.caption).foregroundColor(.gray)
                }
                customFontControls()
                pinnedFooterControls()
                Picker("karaoke_alignment".localized, selection: $karaokeOptions.textAlignment) {
                    ForEach(KaraokeTextAlignment.allCases, id: \.self) { alignment in
                        Text(alignment.displayName).tag(alignment)
                    }
                }

                Toggle(
                    "karaoke_reversed_direction".localized,
                    isOn: $karaokeOptions.reversedDirection
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("karaoke_text_scale".localized)
                        Spacer()
                        Text(String(format: "%.0f%%", karaokeOptions.textScale * 100)).foregroundColor(.gray)
                    }
                    Slider(value: $karaokeOptions.textScale, in: 0.7...1.3, step: 0.01)
                    if abs(karaokeOptions.textScale - 1) > 0.001 {
                        Button("karaoke_text_scale_reset".localized) { karaokeOptions.textScale = 1 }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("karaoke_portrait_header_offset".localized)
                        Spacer()
                        Text(String(format: "%+.0f pt", karaokeOptions.portraitHeaderOffset)).foregroundColor(.gray)
                    }
                    Slider(value: $karaokeOptions.portraitHeaderOffset, in: -80...80, step: 1)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("karaoke_landscape_header_offset".localized)
                        Spacer()
                        Text(String(format: "%+.0f pt", karaokeOptions.landscapeHeaderOffset)).foregroundColor(.gray)
                    }
                    Slider(value: $karaokeOptions.landscapeHeaderOffset, in: -80...80, step: 1)
                    Text("karaoke_landscape_header_offset_help".localized).font(.caption).foregroundColor(.gray)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("karaoke_blur_intensity".localized)
                        Spacer()
                        Text(String(format: "%.1f", karaokeOptions.blurIntensity))
                            .foregroundColor(.gray)
                    }
                    Slider(value: $karaokeOptions.blurIntensity, in: 0...4, step: 0.1)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("karaoke_timing_offset".localized)
                        Spacer()
                        Text(String(format: "%+.0f ms", karaokeOptions.timingOffsetMs)).font(.system(size: 16, design: .monospaced))
                    }
                    Slider(value: $karaokeOptions.timingOffsetMs, in: -3000...3000, step: 25)
                    Text("karaoke_timing_offset_help".localized).font(.caption).foregroundColor(.gray)
                    if karaokeOptions.timingOffsetMs != 0 {
                        Button("karaoke_timing_reset".localized) { karaokeOptions.timingOffsetMs = 0 }
                    }
                }
            }
        } header: {
            Text("karaoke_section".localized)
        } footer: {
            Text("karaoke_section_footer".localized)
        }
    }
    
    @ViewBuilder private func geniusFallbackSection() -> some View {
        Section {
            Toggle(
                "genius_fallback".localized,
                isOn: $viewModel.lyricsOptions.geniusFallback
            )
            
            if viewModel.lyricsOptions.geniusFallback {
                Toggle(
                    "show_fallback_reasons".localized,
                    isOn: $viewModel.lyricsOptions.showFallbackReasons
                )
            }
        } footer: {
            Text("genius_fallback_description"
                .localizeWithFormat(viewModel.lyricsSource.description))
        }
    }
    
    @ViewBuilder private func romanizedLyricsSection() -> some View {
        Section {
            Toggle(
                "romanized_lyrics".localized,
                isOn: $viewModel.lyricsOptions.romanization
            )
        } footer: {
            Text("romanized_lyrics_description".localized)
        }
    }
    
    @ViewBuilder private func hideOnErrorSection() -> some View {
        Section {
            Toggle(
                "hide_lyrics_on_error".localized,
                isOn: $viewModel.lyricsOptions.hideOnError
            )
        } footer: {
            Text("hide_lyrics_on_error_description".localized)
        }
    }
    
    @ViewBuilder private func musixmatchLanguageSection() -> some View {
        Section {
            HStack {
                Text("musixmatch_language".localized)
                
                Spacer()
                
                TextField("en", text: $viewModel.lyricsOptions.musixmatchLanguage)
                    .frame(maxWidth: 20)
                    .foregroundColor(.gray)
            }
            .icon(
                "exclamationmark.triangle.fill",
                color: .yellow,
                when: $viewModel.showMusixmatchInvalidLanguageWarning
            )
        } footer: {
            Text("musixmatch_language_description".localized)
        }
    }
}
