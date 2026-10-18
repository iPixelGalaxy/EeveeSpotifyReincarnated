import Orion
import UIKit

struct PlayerButtonsDeclutterGroup: HookGroup {}
struct PlayerAddToDeclutterGroup: HookGroup {}
struct PlayerLyricsPreviewDeclutterGroup: HookGroup {}
struct PlayerCardsDeclutterGroup: HookGroup {}
struct PlayerAssistantDeclutterGroup: HookGroup {}

enum PlayerPart: String, CaseIterable, Codable {
    case fullScreen, lyricsPreview, shuffle, `repeat`, addTo, queue, share, connect
    case talkAboutSong, aboutSong, artistCircles
    case allCards, lyricsCard, aboutArtist, relatedVideos, songDNA, liveEvents, exploreArtist, releaseCountdown, credits, merch, recommendations

    static let buttons: [PlayerPart] = [.fullScreen, .lyricsPreview, .shuffle, .repeat, .addTo, .queue, .share, .connect]
    static let cards: [PlayerPart] = [.allCards, .talkAboutSong, .aboutSong, .artistCircles, .lyricsCard, .aboutArtist, .relatedVideos, .songDNA, .liveEvents, .exploreArtist, .releaseCountdown, .credits, .merch, .recommendations]

    var buttonIds: [String] {
        switch self {
        case .fullScreen: return ["FullscreenButton", "NowPlayingFullscreenButton", "NowPlaying-FullscreenButton"]
        case .shuffle: return ["Components.UI.ShuffleButton"]
        case .repeat: return ["Nowplaying-RepeatButton"]
        case .share: return ["ShareButtonNowPlayingView"]
        case .queue: return ["QueueButtonNowPlaying"]
        case .connect: return ["Components.ConnectButtonOutputSwitcher"]
        default: return []
        }
    }

    var cardMarkers: [String] {
        switch self {
        case .talkAboutSong: return ["Martini_NPVCardProviderImpl", "ChatEntryPoint", "Martini_FloatingChatImpl", "ChatPill"]
        case .aboutSong: return ["AboutTheSong", "Martini_ElementImpl"]
        case .artistCircles: return ["ArtistPortrait", "ArtistAvatar", "ArtistInfoBubble"]
        case .lyricsCard: return ["Lyrics_CardElementImpl"]
        case .aboutArtist: return ["CreatorBiography"]
        case .relatedVideos: return ["VideoRecommendations"]
        case .songDNA: return ["SongDNA"]
        case .liveEvents: return ["LiveEvents_", "OnTourEventCard"]
        case .exploreArtist: return ["WatchFeed"]
        case .releaseCountdown: return ["Prerelease"]
        case .credits: return ["Creator_Credits"]
        case .merch: return ["Merch_"]
        case .recommendations: return ["RelatedContentRecommendations"]
        default: return []
        }
    }
}

enum PlayerDeclutter {
    static let hidden = Set(UserDefaults.playerOptions.hiddenParts)
    static let cardsMeter = PerfMeter("Player][Cards")
    static let buttonsMeter = PerfMeter("Player][Buttons")
    private static var loggedCards = Set<PlayerPart>()
    private static var cacheKey: UInt8 = 0
    private static var portraitKey: UInt8 = 0
    private static var promptKey: UInt8 = 0
    private static var bounceKey: UInt8 = 0
    private static let cardCollections = NSHashTable<UICollectionView>.weakObjects()
    private static let retryWindow: CFTimeInterval = 5

    private final class Verdict {
        weak var content: UIView?
        let part: PlayerPart?
        let settled: Bool
        let born: CFTimeInterval
        let time = CACurrentMediaTime()
        init(content: UIView?, part: PlayerPart?, settled: Bool, born: CFTimeInterval) {
            self.content = content
            self.part = part
            self.settled = settled
            self.born = born
        }
    }

    static let hiddenIds: Set<String> = Set(hidden.flatMap(\.buttonIds))

    static func hideButtons(in unit: UIViewController) {
        for item in row(in: unit) where item.alpha != 0 {
            let id = item.accessibilityIdentifier ?? item.eeveeFirst(UIView.self) { $0.accessibilityIdentifier != nil }?.accessibilityIdentifier
            if let id, hiddenIds.contains(id) { vanish(item) }
            let identity = ((id ?? "") + (item.accessibilityLabel ?? "")).lowercased()
            if hidden.contains(.fullScreen), identity.contains("fullscreen") || identity.contains("full screen") { vanish(item) }
        }
    }

    static func row(in unit: UIViewController) -> [UIView] {
        unit.viewIfLoaded?.eeveeFirst(UIStackView.self)?.arrangedSubviews ?? []
    }

    // Arranged views vanish by alpha: some Spotify stacks trap when an arranged view is hidden.
    static func vanish(_ view: UIView) {
        guard view.alpha != 0 else { return }
        view.alpha = 0
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
    }

    static func hideArtistCircles(in cell: UIView, below: CGFloat? = nil) {
        guard hidden.contains(.artistCircles) || hidden.contains(.allCards) else { return }
        var queue = cell.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            queue.append(contentsOf: view.subviews)
            let width = view.bounds.width
            let height = view.bounds.height
            guard width >= 48, height >= 48, abs(width - height) < width * 0.1 else { continue }
            let name = NSStringFromClass(type(of: view))
            let circular = view.layer.cornerRadius >= width * 0.45
            let portrait = name.contains("Avatar") || name.contains("Portrait") || name.contains("ArtistAboutImageView")
            guard portrait || circular else { continue }
            if let below, let window = view.window,
               view.convert(view.bounds, to: window).midY < below { continue }
            var ancestor: UIView? = view
            var inPlayer = false
            while let current = ancestor {
                var context = NSStringFromClass(type(of: current))
                if let controller = current.next as? UIViewController { context += NSStringFromClass(type(of: controller)) }
                if context.contains("NowPlaying_Bar") { break }
                if context.contains("NowPlaying") { inPlayer = true; break }
                ancestor = current.superview
            }
            guard inPlayer else { continue }
            let image = view.layer.contents != nil || name.contains("Image") || view.eeveeFirst(UIView.self, where: {
                $0 is UIImageView || $0.layer.contents != nil || NSStringFromClass(type(of: $0)).contains("Image")
            }) != nil
            if portrait || image {
                vanish(view)
                var ancestor = view.superview
                while let current = ancestor {
                    if let cell = current as? UICollectionViewCell,
                       objc_getAssociatedObject(cell, &portraitKey) == nil {
                        objc_setAssociatedObject(cell, &portraitKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        objc_setAssociatedObject(cell, &cacheKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        (cell.superview as? UICollectionView)?.collectionViewLayout.invalidateLayout()
                    }
                    ancestor = current.superview
                }
            }
        }
    }

    private static func hasVisibleContent(_ root: UIView) -> Bool {
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            guard !view.isHidden, view.alpha > 0.01 else { continue }
            if let label = view as? UILabel, !(label.text ?? "").isEmpty { return true }
            if let image = view as? UIImageView, image.image != nil { return true }
            if let button = view as? UIButton,
               !(button.currentTitle ?? "").isEmpty || button.currentImage != nil { return true }
            let name = NSStringFromClass(type(of: view))
            // Opaque renderers may paint text without UILabel descendants; preserve them.
            if name.contains("HostingView") { return true }
            queue.append(contentsOf: view.subviews)
        }
        return false
    }

    static func resetCard(_ cell: UIView) {
        objc_setAssociatedObject(cell, &cacheKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(cell, &portraitKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func hideSongPrompt(_ view: UIView) {
        guard hidden.contains(.talkAboutSong) || hidden.contains(.allCards),
              view.window != nil, view.bounds.width > 1 else { return }
        var branch = view
        // Include the prompt's grey wrapper, but stop before unrelated controls/content.
        while let parent = branch.superview, !(parent is UICollectionViewCell),
              !(parent is UIScrollView), parent.bounds.height <= 140,
              parent.subviews.allSatisfy({ $0 === branch || !hasVisibleContent($0) }) {
            branch = parent
        }
        vanish(branch)
        if objc_getAssociatedObject(view, &promptKey) == nil {
            objc_setAssociatedObject(view, &promptKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            var ancestor = branch.superview
            while let current = ancestor {
                if let cell = current as? UICollectionViewCell {
                    objc_setAssociatedObject(cell, &cacheKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                }
                if let collection = current as? UICollectionView { collection.collectionViewLayout.invalidateLayout() }
                ancestor = current.superview
            }
        }
    }

    private static func cardsAreCollapsed(in root: UIView) -> Bool {
        if hidden.contains(.allCards) { return true }
        let collections = cardCollections.allObjects.filter { $0 === root || $0.isDescendant(of: root) }
        guard !collections.isEmpty else { return false }
        for collection in collections {
            for section in 0..<collection.numberOfSections {
                for item in 0..<collection.numberOfItems(inSection: section) {
                    let index = IndexPath(item: item, section: section)
                    guard let attributes = collection.collectionViewLayout.layoutAttributesForItem(at: index) else { return false }
                    if attributes.isHidden || attributes.size.height <= 1 { continue }
                    // An uninstantiated nonzero item could be a real card; preserve access to it.
                    guard let cell = collection.cellForItem(at: index) else { return false }
                    if cell.eeveeContainsClass("NowPlaying_ModesImpl") { continue }
                    if hiddenCard(for: cell) == nil { return false }
                }
            }
        }
        return true
    }

    /// Once collapsed cards leave no vertical overflow, prevent elastic/stale empty space.
    static func trimEmptyTail(in root: UIView) {
        guard hidden.contains(.allCards) || [.talkAboutSong, .aboutSong, .artistCircles].allSatisfy(hidden.contains) else { return }
        let collapsed = cardsAreCollapsed(in: root)
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if NSStringFromClass(type(of: view)).contains("KaraokeCanvasContainer") { continue }
            queue.append(contentsOf: view.subviews)
            guard let scroll = view as? UIScrollView, let window = scroll.window,
                  scroll.bounds.width >= window.bounds.width * 0.8,
                  scroll.bounds.height >= window.bounds.height * 0.5,
                  scroll.contentSize.width <= scroll.bounds.width + 1 else { continue }
            let empty = collapsed || scroll.contentSize.height <= scroll.bounds.height + 1
            if empty {
                if objc_getAssociatedObject(scroll, &bounceKey) == nil {
                    objc_setAssociatedObject(scroll, &bounceKey, [scroll.bounces, scroll.alwaysBounceVertical, scroll.isScrollEnabled], .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                }
                scroll.bounces = false
                scroll.alwaysBounceVertical = false
                if collapsed { scroll.isScrollEnabled = false }
                let lower = -scroll.adjustedContentInset.top
                let upper = collapsed ? lower : max(lower, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                let y = min(upper, max(lower, scroll.contentOffset.y))
                if abs(y - scroll.contentOffset.y) > 0.5 {
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
                }
            } else if let saved = objc_getAssociatedObject(scroll, &bounceKey) as? [Bool], saved.count == 3 {
                scroll.bounces = saved[0]
                scroll.alwaysBounceVertical = saved[1]
                scroll.isScrollEnabled = saved[2]
                objc_setAssociatedObject(scroll, &bounceKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            // Only the outer player scroll view; never change nested Canvas/carousel scrolling.
            return
        }
    }

    static func hiddenCard(for cell: UIView) -> PlayerPart? {
        let content = (cell as? UICollectionViewCell)?.contentView.subviews.first
        let now = CACurrentMediaTime()
        var born = now
        if let verdict = objc_getAssociatedObject(cell, &cacheKey) as? Verdict, verdict.content === content, content != nil {
            // A card's inner content can arrive after its first check, so unsettled misses expire.
            if verdict.part != nil || verdict.settled || now - verdict.time < 1 { return verdict.part }
            born = verdict.born
        }
        let (part, known) = classify(cell)
        let settled = content != nil && (known || now - born >= retryWindow)
        objc_setAssociatedObject(cell, &cacheKey, Verdict(content: content, part: part, settled: settled, born: born), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return part
    }

    private static func classify(_ cell: UIView) -> (part: PlayerPart?, known: Bool) {
        var ancestor = cell.superview
        while let view = ancestor {
            if type(of: view) == type(of: cell) { return (nil, true) }
            ancestor = view.superview
        }
        var names = ""
        var queue = [cell]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if view !== cell, view is UICollectionView { view.layoutIfNeeded() }
            names += NSStringFromClass(type(of: view))
            if let id = view.accessibilityIdentifier { names += id }
            queue += view.subviews
        }
        guard names.contains("NowPlaying_ScrollAPI") else { return (nil, false) }
        var cardAncestor = cell.superview
        while let current = cardAncestor {
            if let collection = current as? UICollectionView { cardCollections.add(collection); break }
            cardAncestor = current.superview
        }
        if objc_getAssociatedObject(cell, &portraitKey) != nil, !hasVisibleContent(cell) {
            return (.artistCircles, true)
        }
        let matched = PlayerPart.cards.first { part in part.cardMarkers.contains { names.contains($0) } }
        let part: PlayerPart?
        if let matched, hidden.contains(matched) {
            part = matched
        } else if hidden.contains(.allCards), !names.contains("NowPlaying_ModesImpl") {
            part = .allCards
        } else {
            part = nil
        }
        if let part, loggedCards.insert(matched ?? part).inserted {
            eeveeLog("[EeveeSpotify][Player] Collapsed card %@", (matched ?? part).rawValue)
        }
        return (part, matched != nil || names.contains("NowPlaying_ModesImpl"))
    }
}

extension UIView {
    func eeveeContainsClass(_ fragment: String) -> Bool {
        eeveeFirst(UIView.self) { NSStringFromClass(type(of: $0)).contains(fragment) } != nil
    }
}

class PlayerCardCellHook: ClassHook<UICollectionViewCell> {
    typealias Group = PlayerCardsDeclutterGroup
    static let targetName = "_TtC12Element_List18CollectionViewCell"

    func layoutSubviews() {
        orig.layoutSubviews()
        PlayerDeclutter.hideArtistCircles(in: target)
    }

    func prepareForReuse() {
        orig.prepareForReuse()
        PlayerDeclutter.resetCard(target)
    }

    func preferredLayoutAttributesFittingAttributes(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let result = orig.preferredLayoutAttributesFittingAttributes(attributes)
        let part = PlayerDeclutter.cardsMeter.measure { PlayerDeclutter.hiddenCard(for: target) }
        guard part != nil else { return result }
        result.size = CGSize(width: result.size.width, height: 0)
        target.clipsToBounds = true
        return result
    }
}

class PlayerControlsDeclutterHook: ClassHook<UIViewController> {
    typealias Group = PlayerButtonsDeclutterGroup
    static let targetName = "_TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        PlayerDeclutter.buttonsMeter.measure { PlayerDeclutter.hideButtons(in: target) }
    }
}

class PlayerFooterDeclutterHook: ClassHook<UIViewController> {
    typealias Group = PlayerButtonsDeclutterGroup
    static let targetName = "_TtC20NowPlaying_ModesImpl18FooterElementsUnit"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        PlayerDeclutter.buttonsMeter.measure { PlayerDeclutter.hideButtons(in: target) }
    }
}

class PlayerInfoDeclutterHook: ClassHook<UIViewController> {
    typealias Group = PlayerAddToDeclutterGroup
    static let targetName = "_TtC20NowPlaying_ModesImpl23InformationElementsUnit"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        for item in PlayerDeclutter.row(in: target) where item.alpha != 0 && item.eeveeContainsClass("AddToButton") {
            PlayerDeclutter.vanish(item)
        }
    }
}

class PlayerLyricsPreviewHook: ClassHook<UIView> {
    typealias Group = PlayerLyricsPreviewDeclutterGroup
    static let targetName = "_TtC17Canvas_CommonImpl26CanvasNowPlayingLyricsView"

    func layoutSubviews() {
        orig.layoutSubviews()
        PlayerDeclutter.vanish(target)
    }
}

func activatePlayerDeclutter() {
    if !UserDefaults.standard.bool(forKey: "eeveeTrimmedLyricsFooterV1") {
        var options = UserDefaults.playerOptions
        for part in [PlayerPart.share, .queue, .fullScreen, .lyricsPreview, .lyricsCard] where !options.hiddenParts.contains(part) {
            options.hiddenParts.append(part)
        }
        UserDefaults.playerOptions = options
        UserDefaults.standard.set(true, forKey: "eeveeTrimmedLyricsFooterV1")
    }
    let hidden = PlayerDeclutter.hidden
    guard !hidden.isEmpty else { return }
    let start = CFAbsoluteTimeGetCurrent()
    var active = [String]()
    func activate(_ name: String, _ wanted: Bool, _ group: HookGroup, _ classes: String...) {
        guard wanted else { return }
        let missing = classes.filter { NSClassFromString($0) == nil }
        guard missing.isEmpty else {
            eeveeLog("[EeveeSpotify][Player] Skipped %@: missing %@", name, missing.joined(separator: ", "))
            return
        }
        group.activate()
        active.append(name)
    }

    activate("player extras", hidden.contains(.talkAboutSong) || hidden.contains(.artistCircles) || hidden.contains(.allCards),
             PlayerAssistantDeclutterGroup(), PlayerAssistantHook.targetName, PlayerAssistantFooterHook.targetName)
    activate("buttons", !PlayerDeclutter.hiddenIds.isEmpty, PlayerButtonsDeclutterGroup(),
             PlayerControlsDeclutterHook.targetName, PlayerFooterDeclutterHook.targetName)
    activate("add to", hidden.contains(.addTo), PlayerAddToDeclutterGroup(), PlayerInfoDeclutterHook.targetName)
    activate("lyrics preview", hidden.contains(.lyricsPreview), PlayerLyricsPreviewDeclutterGroup(), PlayerLyricsPreviewHook.targetName)
    activate("cards", !hidden.isDisjoint(with: PlayerPart.cards), PlayerCardsDeclutterGroup(), PlayerCardCellHook.targetName)
    eeveeLog("[EeveeSpotify][Player] Declutter: hiding %@; active %@ (%.2f ms)",
             hidden.map(\.rawValue).sorted().joined(separator: ", "), active.joined(separator: ", "),
             (CFAbsoluteTimeGetCurrent() - start) * 1000)
}


/// The prompt can float outside collection cells; suppress its entire root, including its backdrop.
private enum PlayerAssistantVisibility {
    static weak var footer: UIView?
    static let roots = NSHashTable<UIView>.weakObjects()
    private static var savedAlphaKey: UInt8 = 0
    private final class Visibility {
        let alpha: CGFloat
        let interactive: Bool
        let accessibilityHidden: Bool
        init(_ view: UIView) {
            alpha = view.alpha
            interactive = view.isUserInteractionEnabled
            accessibilityHidden = view.accessibilityElementsHidden
        }
    }

    static func refresh() {
        var visible = footer?.window != nil
        if let footer, let window = footer.window {
            visible = footer.convert(footer.bounds, to: window).intersects(window.bounds)
            var ancestor: UIView? = footer
            while let view = ancestor {
                if view.isHidden || view.alpha <= 0.01 { visible = false }
                ancestor = view.superview
            }
        }
        let hidePrompt = visible && (PlayerDeclutter.hidden.contains(.talkAboutSong) || PlayerDeclutter.hidden.contains(.allCards))
        for root in roots.allObjects {
            if hidePrompt {
                if objc_getAssociatedObject(root, &savedAlphaKey) == nil {
                    objc_setAssociatedObject(root, &savedAlphaKey, Visibility(root), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                }
                PlayerDeclutter.vanish(root)
            } else if let alpha = objc_getAssociatedObject(root, &savedAlphaKey) as? Visibility {
                root.alpha = alpha.alpha
                root.isUserInteractionEnabled = alpha.interactive
                root.accessibilityElementsHidden = alpha.accessibilityHidden
                objc_setAssociatedObject(root, &savedAlphaKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
    }
}

class PlayerAssistantHook: ClassHook<UIViewController> {
    typealias Group = PlayerAssistantDeclutterGroup
    static let targetName = "_TtC24Martini_FloatingChatImpl26FloatingChatViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let root = target.viewIfLoaded { PlayerAssistantVisibility.roots.add(root) }
        PlayerAssistantVisibility.refresh()
    }
}

class PlayerAssistantFooterHook: ClassHook<UIViewController> {
    typealias Group = PlayerAssistantDeclutterGroup
    static let targetName = "_TtC20NowPlaying_ModesImpl18FooterElementsUnit"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        PlayerAssistantVisibility.footer = target.viewIfLoaded
        PlayerAssistantVisibility.refresh()
        if let footer = target.viewIfLoaded, let window = footer.window {
            // Portraits may float outside collection cells on the Canvas layout.
            let row = footer.eeveeFirst(UIStackView.self) ?? footer
            let floor = row.convert(row.bounds, to: window).minY
            var playerRoot = footer
            var ancestor: UIView? = footer
            while let view = ancestor, view !== window {
                var name = NSStringFromClass(type(of: view))
                if let controller = view.next as? UIViewController { name += NSStringFromClass(type(of: controller)) }
                if name.contains("NowPlaying"), !name.contains("NowPlaying_Bar") { playerRoot = view }
                ancestor = view.superview
            }
            PlayerDeclutter.hideArtistCircles(in: playerRoot, below: floor)
        }
    }

    func viewDidDisappear(_ animated: Bool) {
        orig.viewDidDisappear(animated)
        PlayerAssistantVisibility.footer = nil
        PlayerAssistantVisibility.refresh()
    }
}


class PlayerSongPromptHook: ClassHook<UIView> {
    typealias Group = PlayerAssistantDeclutterGroup
    static let targetName = "_TtC27Martini_NPVCardProviderImpl18ChatEntryPointView"
    func layoutSubviews() { orig.layoutSubviews(); PlayerDeclutter.hideSongPrompt(target) }
    func didMoveToWindow() { orig.didMoveToWindow(); PlayerDeclutter.hideSongPrompt(target) }
}

class PlayerSongPromptBackgroundHook: ClassHook<UIView> {
    typealias Group = PlayerAssistantDeclutterGroup
    static let targetName = "_TtC27Martini_NPVCardProviderImpl28ChatEntryPointBackgroundView"
    func layoutSubviews() { orig.layoutSubviews(); PlayerDeclutter.hideSongPrompt(target) }
    func didMoveToWindow() { orig.didMoveToWindow(); PlayerDeclutter.hideSongPrompt(target) }
}

class PlayerSongPromptAlternateHook: ClassHook<UIView> {
    typealias Group = PlayerAssistantDeclutterGroup
    static let targetName = "_TtC27Martini_NPVCardProviderImpl35ChatEntryPointContentsAlternateView"
    func layoutSubviews() { orig.layoutSubviews(); PlayerDeclutter.hideSongPrompt(target) }
    func didMoveToWindow() { orig.didMoveToWindow(); PlayerDeclutter.hideSongPrompt(target) }
}

class PlayerEmptyTailHook: ClassHook<UIViewController> {
    typealias Group = PlayerCardsDeclutterGroup
    static let targetName = "_TtC21NowPlaying_ScrollImpl23NPVScrollViewController"
    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let root = target.viewIfLoaded { PlayerDeclutter.trimEmptyTail(in: root) }
    }
}
