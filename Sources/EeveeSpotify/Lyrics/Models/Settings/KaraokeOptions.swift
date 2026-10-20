import Foundation

enum KaraokeTextAlignment: String, Codable, CaseIterable {
    case automatic
    case leading
    case center
    case trailing

    var displayName: String {
        "karaoke_alignment_\(rawValue)".localized
    }
}

enum KaraokePinnedFooterMode: String, Codable, CaseIterable {
    case off
    case noWriters
    case full

    var displayName: String { "karaoke_footer_\(rawValue)".localized }
}

struct KaraokeOptions: Codable, Hashable {
    static let textScaleBaseline: Double = 0.95
    private var textScaleVersion = 1
    var textAlignment: KaraokeTextAlignment = .automatic
    var reversedDirection = false
    var enabled = true
    var blurIntensity: Double = 1.5
    var textScale: Double = 1
    var timingOffsetMs: Double = 0
    var landscapeHeaderOffset: Double = 0
    var portraitHeaderOffset: Double = 0
    var allowScreenRecording = true
    var spaceGravityMode = false
    var smoothScrolling = false
    var earlyScrolling = true
    var scrollLeadMs: Double = 250
    var landscapeCanvas = true
    var pinnedFooterMode: KaraokePinnedFooterMode = .off
    var experimentalWordSplitting = false
    var wordSplittingEnabled: Bool { experimentalWordSplitting || spaceGravityMode }
    var customFontEnabled = false
    var customFontURL = ""

    init(textAlignment: KaraokeTextAlignment = .automatic, reversedDirection: Bool = false, enabled: Bool = true, blurIntensity: Double = 1.5, textScale: Double = 1) {
        self.textAlignment = textAlignment
        self.reversedDirection = reversedDirection
        self.enabled = enabled
        self.blurIntensity = blurIntensity
        self.textScale = min(1.3, max(0.7, textScale))
    }

    private enum CodingKeys: String, CodingKey {
        case textAlignment, reversedDirection, enabled, blurIntensity, timingOffsetMs, landscapeHeaderOffset, portraitHeaderOffset, allowScreenRecording, textScale, textScaleVersion, spaceGravityMode, smoothScrolling, earlyScrolling, scrollLeadMs, landscapeCanvas, pinnedFooterMode, experimentalWordSplitting, customFontEnabled, customFontURL
    }

    // Settings saved before these fields existed must keep decoding.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        textAlignment = try container.decodeIfPresent(KaraokeTextAlignment.self, forKey: .textAlignment) ?? .automatic
        reversedDirection = try container.decodeIfPresent(Bool.self, forKey: .reversedDirection) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        blurIntensity = try container.decodeIfPresent(Double.self, forKey: .blurIntensity) ?? 1.5
        let savedScale = try container.decodeIfPresent(Double.self, forKey: .textScale)
        let scaleVersion = try container.decodeIfPresent(Int.self, forKey: .textScaleVersion) ?? 0
        // Preserve the old size when rebasing the displayed percentage to 100%.
        let normalizedScale = scaleVersion == 0
            ? (savedScale ?? Self.textScaleBaseline) / Self.textScaleBaseline
            : savedScale ?? 1
        textScale = min(1.3, max(0.7, normalizedScale))
        timingOffsetMs = try container.decodeIfPresent(Double.self, forKey: .timingOffsetMs) ?? 0
        portraitHeaderOffset = min(80, max(-80, try container.decodeIfPresent(Double.self, forKey: .portraitHeaderOffset) ?? 0))
        landscapeHeaderOffset = min(80, max(-80, try container.decodeIfPresent(Double.self, forKey: .landscapeHeaderOffset) ?? 0))
        allowScreenRecording = try container.decodeIfPresent(Bool.self, forKey: .allowScreenRecording) ?? true
        spaceGravityMode = try container.decodeIfPresent(Bool.self, forKey: .spaceGravityMode) ?? false
        smoothScrolling = try container.decodeIfPresent(Bool.self, forKey: .smoothScrolling) ?? false
        earlyScrolling = try container.decodeIfPresent(Bool.self, forKey: .earlyScrolling) ?? true
        scrollLeadMs = min(800, max(0, try container.decodeIfPresent(Double.self, forKey: .scrollLeadMs) ?? 250))
        landscapeCanvas = try container.decodeIfPresent(Bool.self, forKey: .landscapeCanvas) ?? true
        pinnedFooterMode = KaraokePinnedFooterMode(rawValue: try container.decodeIfPresent(String.self, forKey: .pinnedFooterMode) ?? "off") ?? .off
        experimentalWordSplitting = try container.decodeIfPresent(Bool.self, forKey: .experimentalWordSplitting) ?? false
        customFontEnabled = try container.decodeIfPresent(Bool.self, forKey: .customFontEnabled) ?? false
        customFontURL = try container.decodeIfPresent(String.self, forKey: .customFontURL) ?? ""
    }
}
