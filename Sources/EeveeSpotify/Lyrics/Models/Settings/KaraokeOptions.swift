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

struct KaraokeOptions: Codable, Hashable {
    static let textScaleBaseline: Double = 0.95
    private var textScaleVersion = 1
    var textAlignment: KaraokeTextAlignment = .automatic
    var reversedDirection = false
    var enabled = true
    var blurIntensity: Double = 1.5
    var textScale: Double = 1
    var timingOffsetMs: Double = 0
    var allowScreenRecording = true

    init(textAlignment: KaraokeTextAlignment = .automatic, reversedDirection: Bool = false, enabled: Bool = true, blurIntensity: Double = 1.5, textScale: Double = 1) {
        self.textAlignment = textAlignment
        self.reversedDirection = reversedDirection
        self.enabled = enabled
        self.blurIntensity = blurIntensity
        self.textScale = min(1.3, max(0.7, textScale))
    }

    private enum CodingKeys: String, CodingKey {
        case textAlignment, reversedDirection, enabled, blurIntensity, timingOffsetMs, allowScreenRecording, textScale, textScaleVersion
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
        allowScreenRecording = try container.decodeIfPresent(Bool.self, forKey: .allowScreenRecording) ?? true
    }
}
