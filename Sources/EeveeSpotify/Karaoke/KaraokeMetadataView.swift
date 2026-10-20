import UIKit

/// Render metadata with the selected font without changing Spotify's label text or ownership.
@available(iOS 15.0, *)
final class KaraokeMetadataView: UIView {
    private struct LabelState {
        weak var label: UILabel?
        let alpha: CGFloat
    }
    private var hiddenLabels: [ObjectIdentifier: LabelState] = [:]
    private let title = UILabel(), artist = UILabel()
    private let release = KaraokeReleaseYear()
    var changed: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for label in [title, artist] {
            label.isHidden = true; label.isAccessibilityElement = true
            label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.65
            addSubview(label)
        }
        release.changed = { [weak self] in self?.changed?() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func hides(_ view: UIView) -> Bool { hiddenLabels[ObjectIdentifier(view)]?.label === view }

    private func nativeFont(_ label: UILabel) -> UIFont {
        if let text = label.attributedText, text.length > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont { return font }
        return label.font
    }
    func update(from root: UIView?, options: KaraokeOptions) {
        guard let root, root.window === window, options.customFontEnabled || options.releaseYearPosition != .off else { clear(); return }
        let state = KaraokePlaybackTracker.shared.releaseYearSnapshot()
        release.update(track: state.track, nativeYear: state.year, enabled: options.releaseYearPosition != .off)
        var candidates = root.subviews, labels = [UILabel]()
        if let label = root as? UILabel { labels.append(label) }
        while let view = candidates.popLast() {
            if let label = view as? UILabel,
               let text = label.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text.rangeOfCharacter(from: .alphanumerics) != nil { labels.append(label) }
            candidates += view.subviews
        }
        labels.sort { nativeFont($0).pointSize > nativeFont($1).pointSize }
        guard let headline = labels.first else { clear(); return }
        let subtitle = labels.first { $0.text != headline.text }
        let artistLabels = subtitle.map { first in labels.filter {
            $0.text != headline.text && abs(nativeFont($0).pointSize - nativeFont(first).pointSize) < 0.5
                && abs($0.convert($0.bounds, to: self).midY - first.convert(first.bounds, to: self).midY) < 4
        }.sorted { $0.convert($0.bounds, to: self).minX < $1.convert($1.bounds, to: self).minX } } ?? []
        let artistTexts = Set(artistLabels.compactMap(\.text))
        let wanted = Set(labels.filter { $0.text == headline.text || artistTexts.contains($0.text ?? "") }.map(ObjectIdentifier.init))
        for key in Array(hiddenLabels.keys) where !wanted.contains(key) {
            if let saved = hiddenLabels.removeValue(forKey: key) { saved.label?.alpha = saved.alpha }
        }
        for label in labels where wanted.contains(ObjectIdentifier(label)) {
            let key = ObjectIdentifier(label)
            if hiddenLabels[key]?.label !== label { hiddenLabels[key] = LabelState(label: label, alpha: label.alpha) }
            label.alpha = 0
        }
        var right = min(bounds.maxX, root.convert(root.bounds, to: self).maxX)
        if let button = root.eeveeFirst(UIControl.self, where: { $0.alpha > 0.1 && $0.convert($0.bounds, to: self).minX > self.bounds.midX }) {
            right = min(right, button.convert(button.bounds, to: self).minX - 8)
        }
        render(title, from: headline, text: headline.text ?? "", right: right)
        if let subtitle = artistLabels.first ?? subtitle {
            var seen = Set<String>()
            var text = artistLabels.compactMap(\.text).filter { seen.insert($0).inserted }.joined(separator: ", ")
            if text.isEmpty { text = subtitle.text ?? "" }
            if let year = release.year, options.releaseYearPosition != .off {
                text = options.releaseYearPosition == .beforeArtist ? "\(year) • \(text)" : "\(text) • \(year)"
            }
            render(artist, from: subtitle, text: text, right: right)
        } else { artist.isHidden = true }
    }
    private func render(_ copy: UILabel, from source: UILabel, text: String, right: CGFloat) {
        let rect = source.convert(source.bounds, to: self)
        let scale = min(1, rect.height / max(1, source.bounds.height))
        let fallback = nativeFont(source).withSize(nativeFont(source).pointSize * scale)
        copy.font = KaraokeFont.shared.font(ofSize: fallback.pointSize, fallback: fallback)
        copy.text = text; copy.textColor = source.textColor; copy.textAlignment = source.textAlignment
        copy.alpha = hiddenLabels[ObjectIdentifier(source)]?.alpha ?? 1
        copy.semanticContentAttribute = source.semanticContentAttribute
        let left = max(0, rect.minX)
        copy.frame = CGRect(x: left, y: rect.minY, width: max(1, right - left), height: max(rect.height, copy.font.lineHeight))
        copy.isHidden = false
    }
    func clear() {
        let saved = hiddenLabels; hiddenLabels.removeAll()
        saved.values.forEach { $0.label?.alpha = $0.alpha }
        title.isHidden = true; artist.isHidden = true
    }
    func restore() { release.stop(); clear() }
}
