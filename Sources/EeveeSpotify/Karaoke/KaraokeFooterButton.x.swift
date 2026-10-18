import Orion
import UIKit

struct KaraokeFooterGroup: HookGroup {}

extension Notification.Name {
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
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
        config.baseForegroundColor = UIColor(white: 1, alpha: 0.85)
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
        button.overrideUserInterfaceStyle = .dark
        button.accessibilityLabel = "karaoke_word_synced_button".localized
        button.addAction(UIAction { _ in KaraokeOverlayPresenter.present() }, for: .primaryActionTriggered)
        return button
    }()

    private static let observer = NotificationCenter.default.addObserver(
        forName: .eeveeKaraokeLyricsChanged, object: nil, queue: .main
    ) { _ in update() }

    private static weak var row: UIStackView?

    static func attach(to root: UIView) {
        _ = observer
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
        update()
    }

    private static func update() {
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
    let start = CFAbsoluteTimeGetCurrent()
    guard NSClassFromString(KaraokeFooterUnitHook.targetName) != nil else {
        eeveeLog("[EeveeSpotify][Karaoke] Footer button skipped: footer unit missing")
        return
    }
    KaraokeFooterGroup().activate()
    eeveeLog("[EeveeSpotify][Karaoke] Footer button active (%.2f ms)", (CFAbsoluteTimeGetCurrent() - start) * 1000)
}
