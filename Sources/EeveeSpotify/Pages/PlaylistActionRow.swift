import EeveeSpotifyC
import UIKit

// Glass shuffle / Play / add row over Spotify's hidden header controls, which still receive every tap.
@available(iOS 26.0, *)
final class PlaylistActionRow: UIView {
    static weak var current: PlaylistActionRow?
    var compactLayout = false {
        didSet { if compactLayout != oldValue { placeCuration(); setNeedsLayout() } }
    }
    let curation = PlaylistCurationBar()
    private var compactButtons: [UIButton] {
        [playButton, shuffledPlayButton] + [curation.compactAddButton].compactMap { $0 }
            + [downloadButton, shuffleButton, addButton, shareButton].filter { !$0.isHidden }
            + curation.compactSecondaryButtons
    }
    var compactHeight: CGFloat { compactHeight(for: bounds.width) }
    private func compactSide(for width: CGFloat) -> CGFloat { max(22, min(40, (width - 44) / 5)) }
    func compactHeight(for width: CGFloat) -> CGFloat {
        let columns = 5
        let rows = (compactButtons.count + columns - 1) / columns
        return CGFloat(rows) * compactSide(for: width) + CGFloat(max(0, rows - 1)) * 6 + 8 + (followControl == nil ? 0 : 48)
    }
    weak var download: UIView? {
        didSet {
            guard download !== oldValue else { return }
            downloadObservations.removeAll()
            guard let download else { return }
            let changed: () -> Void = { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.sync() }
            }
            downloadObservations = [
                download.observe(\.accessibilityIdentifier, options: [.new]) { _, _ in changed() },
                download.observe(\.accessibilityLabel, options: [.new]) { _, _ in changed() },
                download.observe(\.accessibilityValue, options: [.new]) { _, _ in changed() },
                download.observe(\.tintColor, options: [.new]) { _, _ in changed() }
            ]
        }
    }
    private var downloadObservations = [NSKeyValueObservation]()
    weak var shuffle: UIView?
    weak var play: UIView?
    weak var add: UIView?
    weak var share: UIView?
    weak var explore: UIView?
    weak var followControl: UIView?
    weak var anchor: UIView?
    // Spotify's single play button moves into the nav bar once its row collapses; ours steps aside and lets it show there.
    weak var playHolder: UIView?
    weak var controlsRow: UIView?
    private var scrollObservation: NSKeyValueObservation?
    private weak var followed: UIScrollView?
    private var faded = false

    // Hosted outside Spotify's header (adding views there stalls its layout), so it follows the header's scroll itself.
    func follow(_ scrollView: UIScrollView?) {
        guard let scrollView, scrollView !== followed else { return }
        followed = scrollView
        scrollObservation = scrollView.observe(\.contentOffset) { [weak self] _, _ in self?.place() }
    }

    func place() {
        placeCuration()
        guard !compactLayout else { alpha = 1; return }
        guard let host = superview, host.window != nil else { return }
        if let anchor, anchor.window != nil, anchor.bounds.height > 0 {
            let frame = anchor.convert(anchor.bounds, to: host)
            let target = CGRect(x: 0, y: frame.midY - 24, width: host.bounds.width, height: 48)
            if self.frame != target { self.frame = target }
        }
        let pinned = collapsed() || convert(bounds, to: nil).minY < (window?.safeAreaInsets.top ?? 0) + 50
        playHolder.map { holder in
            if holder.alpha != (pinned ? 1 : 0) { holder.alpha = pinned ? 1 : 0 }
            holder.isUserInteractionEnabled = pinned
        }
        guard pinned != faded else { return }
        faded = pinned
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = pinned ? 0 : 1
        }
    }

    func placeCuration() {
        guard curation.hasActions else { return }
        curation.compact = compactLayout
        if compactLayout {
            if bounds.height != compactHeight {
                frame.size.height = compactHeight
                LandscapePlaylistHeader.actionsDidResize(self)
            }
            if curation.superview !== self { addSubview(curation) }
            curation.frame = bounds
            curation.isHidden = false
        } else if let host = superview, let toolbar = curation.toolbar, toolbar.window != nil {
            if curation.superview !== host { host.addSubview(curation) }
            let anchor = toolbar.convert(toolbar.bounds, to: host)
            curation.frame = CGRect(x: 16, y: anchor.midY - 22, width: max(0, host.bounds.width - 32), height: 44)
            curation.isHidden = !curation.frame.intersects(host.bounds)
        } else { curation.isHidden = true }
        curation.setNeedsLayout()
    }

    private func collapsed() -> Bool {
        var view = controlsRow
        while let current = view, current !== superview {
            if current.isHidden || current.alpha < 0.5 { return true }
            view = current.superview
        }
        return false
    }

    private let downloadButton = PlaylistActionRow.circle("arrow.down")
    private let shuffleButton = PlaylistActionRow.circle("shuffle")
    private let shuffleDot: UIView = {
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        dot.layer.cornerRadius = 2
        dot.isUserInteractionEnabled = false
        dot.isHidden = true
        return dot
    }()
    private let addButton = PlaylistActionRow.circle("plus")
    private let followButton: UIButton = {
        var config = UIButton.Configuration.glass()
        config.cornerStyle = .capsule
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = .systemFont(ofSize: 15, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: config)
        button.isHidden = true
        return button
    }()
    private let shareButton = PlaylistActionRow.circle("square.and.arrow.up")
    private let shuffledPlayButton: UIButton = {
        let button = PlaylistActionRow.circle("shuffle")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 17, height: 17)).image { context in
            context.cgContext.scaleBy(x: 17.0 / 25.0, y: 17.0 / 25.0)
            UIImage(systemName: "shuffle", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))?
                .draw(in: CGRect(x: 0, y: 1, width: 22, height: 21))
            context.cgContext.setBlendMode(.clear)
            context.cgContext.fillEllipse(in: CGRect(x: 14, y: 14, width: 12, height: 12))
            context.cgContext.setBlendMode(.normal)
            UIImage(systemName: "play.fill")?.draw(in: CGRect(x: 17, y: 17, width: 8, height: 8))
        }
        button.configuration?.image = image.withRenderingMode(.alwaysTemplate)
        button.accessibilityLabel = "Play shuffled"
        button.isHidden = true
        return button
    }()
    private let playButton: UIButton = {
        var config = UIButton.Configuration.prominentGlass()
        config.cornerStyle = .capsule
        config.baseForegroundColor = .black
        config.imagePadding = 8
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = .systemFont(ofSize: 16, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: config)
        button.tintColor = .white
        return button
    }()

    private static let playImage = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
    private static let pauseImage = UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
    private static let plusImage = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    private static let checkImage = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    private static let downloadImage = UIImage(systemName: "arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    private static let downloadedImage = UIImage(systemName: "arrow.down.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    private static let downloadingImage = UIImage(systemName: "arrow.down.circle.dotted", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    private static let playTitle = "playlist_play".localized
    private static let pauseTitle = "playlist_pause".localized

    private static func circle(_ symbol: String) -> UIButton {
        var config = UIButton.Configuration.glass()
        config.cornerStyle = .capsule
        config.baseForegroundColor = .white
        config.contentInsets = .zero
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        return UIButton(configuration: config)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .dark
        [downloadButton, shuffleButton, playButton, shuffledPlayButton, addButton, shareButton, followButton].forEach(addSubview)
        downloadButton.isHidden = true
        downloadButton.addAction(UIAction { [weak self] _ in self?.forward(self?.download, "download") }, for: .primaryActionTriggered)
        shuffleButton.addSubview(shuffleDot)
        shuffleButton.addAction(UIAction { [weak self] _ in self?.forward(self?.shuffle, "shuffle") }, for: .primaryActionTriggered)
        playButton.addAction(UIAction { [weak self] _ in self?.forward(self?.play, "play") }, for: .primaryActionTriggered)
        shuffledPlayButton.addAction(UIAction { [weak self] _ in self?.playShuffled() }, for: .primaryActionTriggered)
        addButton.addAction(UIAction { [weak self] _ in self?.forward(self?.add, "add") }, for: .primaryActionTriggered)
        followButton.addAction(UIAction { [weak self] _ in self?.forward(self?.followControl, "follow") }, for: .primaryActionTriggered)
        shareButton.addAction(UIAction { [weak self] _ in self?.forward(self?.share, "share") }, for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Leave room for Liquid Glass's press effect; the grid has ten-point side gutters.
        clipsToBounds = false
        curation.clipsToBounds = false
        shuffledPlayButton.isHidden = !compactLayout
        if compactLayout {
            curation.frame = bounds
            let circles = compactButtons
            let side = compactSide(for: bounds.width), gap: CGFloat = 6
            let columns = 5
            let gridWidth = CGFloat(columns) * side + CGFloat(columns - 1) * gap
            let left = max(0, (bounds.width - gridWidth) / 2)
            for (index, button) in circles.enumerated() {
                let frame = CGRect(x: left + CGFloat(index % columns) * (side + gap), y: 4 + CGFloat(index / columns) * (side + gap), width: side, height: side)
                button.frame = button.superview === curation ? curation.convert(frame, from: self) : frame
                var config = button.configuration
                config?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: min(17, side * 0.53), weight: .semibold)
                if button === playButton { config?.title = nil }
                if button.configuration != config { button.configuration = config }
            }
            shuffleDot.center = CGPoint(x: side / 2, y: side - 7)
            followButton.frame = CGRect(x: 0, y: compactHeight - 40, width: bounds.width, height: 40)
            return
        }
        let side: CGFloat = 48, gap: CGFloat = 12
        let y = (bounds.height - side) / 2
        var playWidth: CGFloat = 140
        if let explore, explore.window != nil, explore.bounds.width > 0 {
            let clear = explore.convert(explore.bounds, to: self).maxX + 8
            playWidth = max(96, min(playWidth, 2 * (bounds.midX - clear - side - gap)))
        }
        playButton.frame = CGRect(x: bounds.midX - playWidth / 2, y: y, width: playWidth, height: side)
        shuffleButton.frame = CGRect(x: playButton.frame.minX - gap - side, y: y, width: side, height: side)
        downloadButton.frame = CGRect(x: shuffleButton.frame.minX - gap - side, y: y, width: side, height: side)
        shuffleDot.center = CGPoint(x: side / 2, y: side - 7)
        var x = playButton.frame.maxX + gap
        for button in [addButton, shareButton, followButton] where !button.isHidden {
            let width = button === followButton ? max(side, button.intrinsicContentSize.width) : side
            button.frame = CGRect(x: x, y: y, width: width, height: side)
            x += width + gap
        }
    }

    @discardableResult private func forward(_ source: UIView?, _ name: String) -> Bool {
        guard let source else { return false }
        let fired = EeveeFireTap(source)
        if !fired { eeveeLog("[EeveeSpotify][Glass] Playlist %@ tap FAILED", name) }
        for delay in [0.4, 1.2, 2.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.sync() } }
        return fired
    }

    private func playShuffled() {
        sync()
        guard shuffle != nil, play != nil else { return }
        if shuffleDot.isHidden, !forward(shuffle, "shuffle") { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let label = play?.accessibilityLabel ?? play?.eeveeFirst(UIControl.self)?.accessibilityLabel ?? ""
            if !label.lowercased().contains("pause") { forward(play, "play shuffled") }
        }
    }

    func sync() {
        shuffledPlayButton.isEnabled = shuffle != nil && play != nil
        let downloadHidden = download == nil
        if downloadButton.isHidden != downloadHidden { downloadButton.isHidden = downloadHidden; setNeedsLayout() }
        let state = ((download?.accessibilityLabel ?? "") + " " + (download?.accessibilityValue ?? "")).lowercased()
        let selected = (download as? UIControl)?.isSelected == true
            || download?.eeveeFirst(UIControl.self, where: { $0.isSelected }) != nil
            || download?.accessibilityTraits.contains(.selected) == true
        let greenIcon = download?.eeveeFirst(UIImageView.self, where: {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            return $0.tintColor.getRed(&r, green: &g, blue: &b, alpha: &a) && a > 0.5 && g > r + 0.15 && g > b + 0.1
        }) != nil
        let identifier = download?.accessibilityIdentifier ?? ""
        let downloaded = identifier.hasSuffix(".Downloaded") || selected || greenIcon || state.contains("remove") || (state.contains("downloaded") && !state.contains("not downloaded"))
        let downloading = !downloaded && identifier.hasSuffix(".Downloading")
        var downloadConfig = downloadButton.configuration
        downloadConfig?.image = downloaded ? Self.downloadedImage : downloading ? Self.downloadingImage : Self.downloadImage
        downloadConfig?.baseForegroundColor = downloaded ? UIColor(red: 25.0 / 255, green: 181.0 / 255, blue: 81.0 / 255, alpha: 1) : .white
        if downloadButton.configuration != downloadConfig { downloadButton.configuration = downloadConfig }
        downloadButton.accessibilityLabel = download?.accessibilityLabel
        downloadButton.accessibilityValue = downloaded ? "Downloaded" : downloading ? "Downloading" : download?.accessibilityValue
        downloadButton.accessibilityTraits = downloaded ? [.button, .selected] : .button
        if addButton.isHidden != (add == nil) {
            addButton.isHidden = add == nil
            setNeedsLayout()
        }
        let followTitle = followControl?.eeveeFirst(UILabel.self)?.text
        var followConfig = followButton.configuration
        followConfig?.title = followTitle
        if followButton.configuration != followConfig || followButton.isHidden != (followTitle == nil) {
            followButton.configuration = followConfig
            followButton.isHidden = followTitle == nil
            setNeedsLayout()
        }
        if shareButton.isHidden != (share == nil) {
            shareButton.isHidden = share == nil
            setNeedsLayout()
        }
        let playing = (play?.accessibilityLabel ?? play?.eeveeFirst(UIControl.self)?.accessibilityLabel)?.lowercased().contains("pause") == true
        var config = playButton.configuration
        config?.image = playing ? Self.pauseImage : Self.playImage
        config?.title = compactLayout ? nil : playing ? Self.pauseTitle : Self.playTitle
        if !compactLayout { config?.preferredSymbolConfigurationForImage = nil }
        playButton.accessibilityLabel = playing ? Self.pauseTitle : Self.playTitle
        if playButton.configuration != config { playButton.configuration = config }

        let liked = add?.accessibilityLabel?.lowercased().contains("remove") == true
        var addConfig = addButton.configuration
        addConfig?.image = liked ? Self.checkImage : Self.plusImage
        addConfig?.baseForegroundColor = liked ? Theme.accent : .white
        if addButton.configuration != addConfig { addButton.configuration = addConfig }

        // Spotify marks shuffle with a small dot under its icon and swaps the icon for smart shuffle.
        let dot = shuffle?.eeveeFirst(UIView.self) { $0.bounds.width <= 8 && $0.bounds.width > 0 && $0.backgroundColor != nil && !$0.isHidden && $0.alpha > 0.01 }
        let shuffled = (shuffle as? UIControl)?.isSelected == true
            || shuffle?.eeveeFirst(UIControl.self, where: { $0.isSelected }) != nil || dot != nil
        var shuffleConfig = shuffleButton.configuration
        shuffleConfig?.baseForegroundColor = shuffled ? Theme.accent : .white
        if let icon = shuffle?.eeveeFirst(UIImageView.self, where: { $0.image != nil && $0.bounds.width >= 16 })?.image {
            shuffleConfig?.image = icon.withRenderingMode(.alwaysTemplate)
        }
        shuffleDot.isHidden = !shuffled
        shuffleDot.backgroundColor = Theme.accent
        if shuffleButton.configuration != shuffleConfig { shuffleButton.configuration = shuffleConfig }
    }
}
