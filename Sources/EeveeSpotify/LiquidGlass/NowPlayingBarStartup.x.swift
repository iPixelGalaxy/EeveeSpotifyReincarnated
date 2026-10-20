import Orion
import UIKit

/// Display-only restoration while Spotify obtains the current Connect session.
/// Cached metadata never enters Spotify's player state or transport controls.
@available(iOS 26.0, *)
enum NowPlayingBarStartup {
    private static let cacheKey = "eeveeLastPlaybackBarTrack"
    private static let cacheLock = NSLock()
    private static var lastSavedIdentity = ""
    private static var receivedTrack = false
    private static let launchTrack = UserDefaults.standard.dictionary(forKey: cacheKey)
    private static weak var nativeCard: UIView?
    private static var loading: ReconnectingPlaybackBar?
    private static var timer: Timer?
    private static var activation: NSObjectProtocol?
    private static var deadline: TimeInterval = 0
    private static var finished = false

    static func activate() {
        guard activation == nil else { return }
        activation = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
            navigationReady(in: window)
        }
    }

    static func record(_ state: AnyObject?) {
        // Read the prior launch's cache before this launch's first live update replaces it.
        _ = launchTrack
        guard let state = state as? NSObject, state.responds(to: NSSelectorFromString("track")),
              let track = state.perform(NSSelectorFromString("track"))?.takeUnretainedValue() as? NSObject,
              track.responds(to: NSSelectorFromString("trackTitle")),
              track.responds(to: NSSelectorFromString("artistTitle")),
              track.responds(to: NSSelectorFromString("URI")),
              let title = track.perform(NSSelectorFromString("trackTitle"))?.takeUnretainedValue() as? String,
              !title.isEmpty,
              let url = track.perform(NSSelectorFromString("URI"))?.takeUnretainedValue() as? NSURL else { return }
        let uri = url.absoluteString ?? ""
        guard uri.hasPrefix("spotify:track:") || uri.hasPrefix("spotify:episode:") else { return }
        let artist = track.perform(NSSelectorFromString("artistTitle"))?.takeUnretainedValue() as? String ?? ""
        let identity = uri + "\n" + title + "\n" + artist
        cacheLock.lock()
        receivedTrack = true
        let changed = identity != lastSavedIdentity
        if changed { lastSavedIdentity = identity }
        cacheLock.unlock()
        guard changed else { return }
        // Defaults notifications can call UI observers synchronously; never hold the state lock here.
        let saved: [String: Any] = ["title": title, "artist": artist, "saved": Date()]
        UserDefaults.standard.set(saved, forKey: cacheKey)
    }

    static func nativeReady(_ card: UIView) {
        guard !finished else { return }
        nativeCard = card
        if isVisible(card) { finish() }
    }

    static func ownsLoadingHit(_ view: UIView?) -> Bool {
        guard let loading, let view else { return false }
        return view.isDescendant(of: loading)
    }

    static func navigationReady(in window: UIWindow) {
        guard !finished, LiquidGlass.launchOptions.nowPlayingBar else { return }
        if let nativeCard, isVisible(nativeCard) { finish(); return }
        guard let track = launchTrack, let title = track["title"] as? String,
              let saved = track["saved"] as? Date, Date().timeIntervalSince(saved) < 7 * 24 * 60 * 60,
              let host = window.rootViewController?.viewIfLoaded,
              host.window === window else { return }
        // Wait for logged-in navigation; never put previous playback on a login screen.
        guard window.eeveeFirst(UIView.self, where: {
            $0 is UITabBar || NSStringFromClass(type(of: $0)).contains("NavigationUI_TabBar")
        }) != nil else { return }
        if loading == nil {
            let bar = ReconnectingPlaybackBar(title: title, artist: track["artist"] as? String ?? "")
            loading = bar
            host.addSubview(bar)
            deadline = ProcessInfo.processInfo.systemUptime + 15
            let refresh = Timer(timeInterval: 0.1, repeats: true) { [weak window] _ in
                guard let window else { finish(); return }
                if ProcessInfo.processInfo.systemUptime >= deadline { finish(); return }
                navigationReady(in: window)
            }
            timer = refresh
            RunLoop.main.add(refresh, forMode: .common)
            eeveeLog("[NowPlayingBar][Startup] displaying last-known track while reconnecting")
        }
        guard let loading else { return }
        let rect: CGRect
        if let landscape = LandscapeNavigation.playbackFrame(in: window) { rect = landscape }
        else {
            let tabs = GlassTabBar.capsuleFrame(in: window)
            let safe = window.safeAreaLayoutGuide.layoutFrame
            rect = CGRect(x: tabs?.minX ?? safe.minX + 8,
                          y: (tabs?.minY ?? safe.maxY - 68) - 64,
                          width: tabs?.width ?? safe.width - 16, height: 56)
        }
        let local = host.convert(rect, from: window)
        if loading.frame != local { loading.frame = local }
    }

    private static func isVisible(_ card: UIView) -> Bool {
        cacheLock.lock()
        let hasTrack = receivedTrack
        cacheLock.unlock()
        guard hasTrack else { return false }
        guard let window = card.window, card.bounds.width > 1, card.bounds.height > 1,
              card.convert(card.bounds, to: window).intersects(window.bounds) else { return false }
        var current: UIView? = card
        while let view = current {
            if view.isHidden || view.alpha <= 0.01 { return false }
            current = view.superview
        }
        return true
    }

    private static func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate(); timer = nil
        guard let bar = loading else { return }
        loading = nil
        bar.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.15, animations: { bar.alpha = 0 }) { _ in bar.removeFromSuperview() }
        eeveeLog("[NowPlayingBar][Startup] restoration finished at %.2fs", Date().timeIntervalSince(tweakInitTime))
    }
}

@available(iOS 26.0, *)
private final class ReconnectingPlaybackBar: UIView {
    private let icon = UIImageView(image: UIImage(systemName: "music.note"))
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let glass: UIVisualEffectView

    init(title: String, artist: String) {
        glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        super.init(frame: .zero)
        overrideUserInterfaceStyle = .dark
        clipsToBounds = true
        glass.isUserInteractionEnabled = false
        glass.cornerConfiguration = .capsule()
        addSubview(glass)
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        addSubview(icon)
        titleLabel.text = artist.isEmpty ? title : "\(title) · \(artist)"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        let status = "npb_reconnecting".localized
        statusLabel.text = status == "npb_reconnecting" ? "Reconnecting…" : status
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        statusLabel.font = .systemFont(ofSize: 11)
        addSubview(statusLabel)
        spinner.color = .white
        spinner.startAnimating()
        addSubview(spinner)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = "\(titleLabel.text ?? title), \(statusLabel.text ?? "")"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        glass.frame = bounds
        icon.frame = CGRect(x: 14, y: (bounds.height - 24) / 2, width: 24, height: 24)
        let width = max(0, bounds.width - 94)
        titleLabel.frame = CGRect(x: 48, y: bounds.midY - 16, width: width, height: 17)
        statusLabel.frame = CGRect(x: 48, y: bounds.midY + 2, width: width, height: 14)
        spinner.center = CGPoint(x: bounds.maxX - 24, y: bounds.midY)
    }
}

class NowPlayingBarStartupStateHook: ClassHook<NSObject> {
    typealias Group = GlassNowPlayingBarGroup
    static let targetName = "SPTEsperantoPlayer"

    @objc(emitStateUpdate:oldState:observer:)
    func emitStateUpdate(_ state: AnyObject?, oldState: AnyObject?, observer: AnyObject) {
        orig.emitStateUpdate(state, oldState: oldState, observer: observer)
        if #available(iOS 26.0, *) { NowPlayingBarStartup.record(state) }
    }
}
