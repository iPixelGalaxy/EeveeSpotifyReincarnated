import Orion
import UIKit

struct KaraokeFooterGroup: HookGroup {}

extension Notification.Name {
    static let eeveeKaraokeOptionsChanged = Notification.Name("EeveeKaraokeOptionsChanged")
    static let eeveeKaraokeLyricsChanged = Notification.Name("EeveeKaraokeLyricsChanged")
}

class KaraokeFooterUnitHook: ClassHook<UIViewController> {
    typealias Group = KaraokeFooterGroup
    static let targetName = "_TtC20NowPlaying_ModesImpl18FooterElementsUnit"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        guard #available(iOS 15.0, *), let root = target.viewIfLoaded else { return }
        KaraokeFooterButton.meter.measure { KaraokeFooterButton.attach(to: root) }
    }
}

@available(iOS 15.0, *)
enum KaraokeFooterButton {
    static let meter = PerfMeter("Karaoke][FooterButton")

    private static let button: UIButton = {
        let button = UIButton(type: .custom)
        button.setImage(SpotifyLyricsIcon.image(), for: .normal)
        button.tintColor = UIColor(white: 1, alpha: 0.85)
        button.backgroundColor = .clear
        button.layer.borderWidth = 0
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
        button.overrideUserInterfaceStyle = .dark
        button.accessibilityLabel = "karaoke_word_synced_button".localized
        button.addAction(UIAction { _ in KaraokeOverlayPresenter.toggle() }, for: .primaryActionTriggered)
        return button
    }()

    private static let observer = NotificationCenter.default.addObserver(
        forName: .eeveeKaraokeLyricsChanged, object: nil, queue: .main
    ) { _ in update() }

    private static weak var row: UIStackView?

    static func attach(to root: UIView, isDJ: Bool = false) {
        _ = observer
        KaraokeOverlayPresenter.registerPlayer(root)
        if isDJ {
            row = nil
            if button.superview !== root { button.removeFromSuperview(); root.addSubview(button) }
            button.translatesAutoresizingMaskIntoConstraints = true
            button.frame = CGRect(x: root.bounds.midX - 20, y: max(root.bounds.minY, root.bounds.maxY - 48), width: 40, height: 44)
            update()
            return
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        if row?.isDescendant(of: root) != true {
            row = root.eeveeFirst(UIStackView.self, where: { $0.arrangedSubviews.count >= 2 })
        }
        guard let row else { return }
        // Join the native row immediately before its trailing share/queue controls.
        // Arranged layout keeps Spotify responsible for spacing and avoids overlap.
        if button.superview !== row {
            button.removeFromSuperview()
            row.insertArrangedSubview(button, at: max(0, row.arrangedSubviews.count - 2))
        }
        if [PlayerPart.share, .queue, .fullScreen].allSatisfy(UserDefaults.playerOptions.hiddenParts.contains) {
            if let index = row.arrangedSubviews.firstIndex(of: button) {
                for view in row.arrangedSubviews.dropFirst(index + 1) { view.isHidden = true }
            }
            let bottom = row.convert(row.bounds, to: root).maxY
            var queue = root.subviews
            while !queue.isEmpty {
                let view = queue.removeFirst()
                queue.append(contentsOf: view.subviews)
                guard view !== row, !row.isDescendant(of: view), !view.isDescendant(of: row),
                      view.bounds.height > 0, view.convert(view.bounds, to: root).minY >= bottom - 1 else { continue }
                view.alpha = 0
                view.isUserInteractionEnabled = false
                view.accessibilityElementsHidden = true
                if let stack = view.superview as? UIStackView, stack.arrangedSubviews.contains(view) { view.isHidden = true }
            }
        }
        update()
    }

    private static func update() {
        let enabled = KaraokeOverlayPresenter.isEnabled
        let color = enabled ? UIColor(red: 30 / 255, green: 215 / 255, blue: 96 / 255, alpha: 1)
            : UIColor(white: 1, alpha: 0.85)
        button.tintColor = color
        // Accessibility selection is independent of UIKit's selected-button decoration.
        button.accessibilityTraits = enabled ? [.button, .selected] : [.button]
        button.accessibilityValue = (enabled ? "karaoke_state_enabled" : "karaoke_state_disabled").localized
        KaraokeOverlayPresenter.restoreIfNeeded()
        let tracker = KaraokePlaybackTracker.shared
        let unavailable = !UserDefaults.karaokeOptions.enabled
            || !UserDefaults.lyricsSource.supportsCustomLyricsView
            || (tracker.playerReportedTrackId() ?? tracker.currentTrackId()) == nil
        // Spotify owns this stack; avoid its hidden-arranged-view bookkeeping.
        button.alpha = unavailable ? 0 : 1
        button.isUserInteractionEnabled = !unavailable
        button.accessibilityElementsHidden = unavailable
    }
}

func activateKaraokeFooterButton() {
    guard #available(iOS 15.0, *), UserDefaults.lyricsSource.supportsCustomLyricsView else { return }
    KaraokeFont.shared.configure(UserDefaults.karaokeOptions)
    let start = CFAbsoluteTimeGetCurrent()
    guard NSClassFromString(KaraokeFooterUnitHook.targetName) != nil else {
        eeveeLog("[EeveeSpotify][Karaoke] Footer button skipped: footer unit missing")
        return
    }
    KaraokeFooterGroup().activate()
    activateKaraokeDJHooks()
    eeveeLog("[EeveeSpotify][Karaoke] Footer button active (%.2f ms)", (CFAbsoluteTimeGetCurrent() - start) * 1000)
}

class KaraokeCoverHostHook: ClassHook<UIView> {
    typealias Group = KaraokeFooterGroup
    static let targetName = KaraokeOverlayPresenter.coverClass

    func layoutSubviews() {
        orig.layoutSubviews()
        KaraokeOverlayPresenter.layout(in: target)
    }

    func didMoveToWindow() {
        orig.didMoveToWindow()
        KaraokeOverlayPresenter.layout(in: target)
        KaraokeOverlayPresenter.detached(target)
    }
}


class KaraokeCanvasUnitHook: ClassHook<UIViewController> {
    typealias Group = KaraokeFooterGroup
    static let targetName = "_TtC35NowPlaying_ContentLayerPlatformImpl26ContentLayerViewController"

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        if let view = target.viewIfLoaded { KaraokeOverlayPresenter.registerCanvas(view) }
    }

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let view = target.viewIfLoaded { KaraokeOverlayPresenter.registerCanvas(view) }
    }
}

class KaraokeHeaderUnitHook: ClassHook<UIViewController> {
    typealias Group = KaraokeFooterGroup
    static let targetName = "_TtC20NowPlaying_ModesImpl18HeaderElementsUnit"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let view = target.viewIfLoaded { KaraokeOverlayPresenter.registerHeader(view) }
    }
}

class KaraokeInformationUnitHook: ClassHook<UIViewController> {
    typealias Group = KaraokeFooterGroup
    static let targetName = "_TtC20NowPlaying_ModesImpl23InformationElementsUnit"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let view = target.viewIfLoaded { KaraokeOverlayPresenter.registerInformation(view) }
    }
}

class KaraokeControlsUnitHook: ClassHook<UIViewController> {
    typealias Group = KaraokeFooterGroup
    static let targetName = "_TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit"
    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let view = target.viewIfLoaded { KaraokeOverlayPresenter.registerControls(view) }
    }
    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        if let view = target.viewIfLoaded { KaraokeOverlayPresenter.registerControls(view) }
    }

}

class KaraokeDurationUnitHook: ClassHook<UIViewController> {
    typealias Group = KaraokeFooterGroup
    static let targetName = "_TtC20NowPlaying_ModesImpl19DurationElementUnit"
    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let view = target.viewIfLoaded { KaraokeOverlayPresenter.registerDuration(view) }
    }
    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        if let view = target.viewIfLoaded { KaraokeOverlayPresenter.registerDuration(view) }
    }

}

/// The stock lyrics header is a separate unit from the normal playback footer.
class KaraokeStockLyricsHeaderHook: ClassHook<UIView> {
    typealias Group = KaraokeFooterGroup
    static let targetName = "_TtC22Lyrics_CardElementImpl14CardHeaderView"
    func layoutSubviews() {
        orig.layoutSubviews()
        if KaraokeOverlayPresenter.isEnabled && PlayerPlacement.contains(target) {
            target.alpha = 0
            target.isUserInteractionEnabled = false
            target.accessibilityElementsHidden = true
        }
    }
}

class KaraokePlayerLifecycleHook: ClassHook<UIViewController> {
    typealias Group = KaraokeFooterGroup
    static let targetName = "_TtC21NowPlaying_ScrollImpl23NPVScrollViewController"
    func viewWillAppear(_ animated: Bool) {
        KaraokeOverlayPresenter.preparePlayer(target)
        orig.viewWillAppear(animated)
    }
    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        KaraokeOverlayPresenter.resumePlayer(target)
    }
    func viewDidDisappear(_ animated: Bool) {
        orig.viewDidDisappear(animated)
        KaraokeOverlayPresenter.suspendPlayer()
    }
    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        KaraokeOverlayPresenter.layoutPlayer(target)
    }
}

class KaraokeVideoSwitchHook: ClassHook<UIView> {
    typealias Group = KaraokeFooterGroup
    static let targetName = "_TtC22NowPlaying_ElementsKit22AudioVideoSwitchButton"
    func layoutSubviews() {
        orig.layoutSubviews()
        KaraokeOverlayPresenter.suppressVideoSwitch(target)
    }
    func didMoveToWindow() {
        orig.didMoveToWindow()
        KaraokeOverlayPresenter.suppressVideoSwitch(target)
    }
}

// Scope native visibility/style writes to the instances pinned during compact mode.
class KaraokeCompactVisibilityHook: ClassHook<UIView> {
    typealias Group = KaraokeFooterGroup
    @objc(setAlpha:) func setAlpha(_ alpha: CGFloat) {
        orig.setAlpha(KaraokeOverlayPresenter.lockedCompactAlpha(alpha, in: target))
    }
    @objc(setHidden:) func setHidden(_ hidden: Bool) {
        orig.setHidden(KaraokeOverlayPresenter.lockedCompactHidden(hidden, in: target))
    }
    @objc(setClipsToBounds:) func setClipsToBounds(_ clips: Bool) {
        orig.setClipsToBounds(KaraokeOverlayPresenter.lockedCompactClipping(clips, in: target))
    }
    @objc(setUserInteractionEnabled:) func setUserInteractionEnabled(_ enabled: Bool) {
        orig.setUserInteractionEnabled(KaraokeOverlayPresenter.lockedCompactAlpha(enabled ? 1 : 0, in: target) > 0)
    }
    @objc(setTransform:) func setTransform(_ transform: CGAffineTransform) {
        orig.setTransform(KaraokeOverlayPresenter.lockedCompactTransform(transform, in: target))
    }
    func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        orig.point(inside: point, with: event) || KaraokeOverlayPresenter.compactHit(point, in: target)
    }
}

class KaraokeApplicationRotationHook: ClassHook<UIApplication> {
    typealias Group = KaraokeFooterGroup
    func supportedInterfaceOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        KaraokeRotation.applicationMask(for: window) ?? orig.supportedInterfaceOrientations(for: window)
    }
}
