import Orion
import UIKit

@available(iOS 26.0, *)
enum LandscapePlaylistHeader {
    private static var headerKey: UInt8 = 0
    private static var pageKey: UInt8 = 0
    private static var pageRootKey: UInt8 = 0
    private static let pages = NSHashTable<UIView>.weakObjects()
    private static let headers = NSHashTable<UIView>.weakObjects()
    private static var updating = false

    private final class Page {
        weak var root: UIView?
        weak var scroll: UIScrollView?
        let list: NativeViewPlacement?
        let cover = UIImageView()
        let sidebar = UIScrollView()
        let title = UILabel()
        let summary = UILabel()
        let dock = LandscapePlaylistDock()
        var actions: PlaylistActionRow?
        private var sources = [UIView]()
        private var targets = [AnyObject]()
        private var coverObservations = [NSKeyValueObservation]()
        private let coverSources = NSHashTable<UIImageView>.weakObjects()
        let inset: UIEdgeInsets
        let indicators: UIEdgeInsets
        let adjustment: UIScrollView.ContentInsetAdjustmentBehavior
        let clips: Bool
        let background: UIColor?
        private weak var nativeHeader: UIView?
        private var headerAlpha: CGFloat = 1
        var visible = true
        init(root: UIView, list: UIScrollView) {
            self.root = root; scroll = list
            self.list = root === list ? nil : NativeViewPlacement(list)
            inset = list.contentInset; indicators = list.verticalScrollIndicatorInsets
            adjustment = list.contentInsetAdjustmentBehavior
            clips = root.clipsToBounds; background = list.backgroundColor
            cover.contentMode = .scaleAspectFill; cover.clipsToBounds = true
            cover.layer.cornerRadius = 10; cover.layer.cornerCurve = .continuous
            cover.isAccessibilityElement = true; cover.accessibilityTraits = .image
            cover.accessibilityLabel = "Playlist cover"
            sidebar.showsVerticalScrollIndicator = false
            sidebar.contentInsetAdjustmentBehavior = .never
            title.font = .systemFont(ofSize: 17, weight: .bold); title.textColor = .white; title.numberOfLines = 2
            summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabel; summary.numberOfLines = 2
            [cover, title, summary].forEach(sidebar.addSubview)
            objc_setAssociatedObject(list, &pageRootKey, PageLookup.WeakView(root), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        func track(_ sources: [UIImageView]) {
            let previous = coverSources.allObjects
            guard previous.count != sources.count || sources.contains(where: { source in !previous.contains(where: { $0 === source }) }) else { return }
            coverObservations.removeAll(); coverSources.removeAllObjects()
            sources.forEach { coverSources.add($0) }
            coverObservations = sources.map { source in
                source.observe(\.image, options: [.initial, .new]) { [weak self] _, _ in
                    DispatchQueue.main.async { [weak self] in self?.updateCover() }
                }
            }
        }
        private func updateCover() {
            func score(_ view: UIImageView) -> CGFloat {
                guard let image = view.image else { return -1 }
                let pixels = CGFloat(image.cgImage?.width ?? 0) * CGFloat(image.cgImage?.height ?? 0)
                let square = min(image.size.width, image.size.height) / max(1, max(image.size.width, image.size.height))
                return (view.contentMode == .scaleAspectFill || view.contentMode == .scaleAspectFit ? 1_000_000 : 0) + pixels * square
            }
            // Watch every candidate: the cover can arrive after the shadow and placeholder.
            if let image = coverSources.allObjects.filter({ $0.image != nil }).max(by: { score($0) < score($1) })?.image,
               cover.image !== image { cover.image = image }
        }
        func restore() {
            coverObservations.removeAll(); coverSources.removeAllObjects()
            let offset = scroll?.contentOffset
            list?.restore()
            root?.clipsToBounds = clips
            nativeHeader?.alpha = headerAlpha
            scroll?.backgroundColor = background
            if let scroll {
                scroll.contentInsetAdjustmentBehavior = adjustment
                scroll.contentInset = inset; scroll.verticalScrollIndicatorInsets = indicators
                if let offset { scroll.contentOffset = offset }
                objc_setAssociatedObject(scroll, &pageRootKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            dock.restore()
            if let actions {
                actions.compactLayout = false
                root?.addSubview(actions)
                actions.sync(); actions.place()
            }
            sources.removeAll(); targets.removeAll()
            sidebar.removeFromSuperview()
            if let root { LandscapeNavigation.setPlaylist(root, visible: false) }
        }
        func suspend() {
            sidebar.removeFromSuperview(); dock.restore()
            sources.removeAll(); targets.removeAll()
        }
        func metadata(_ header: UIView) {
            let hero = header.accessibilityIdentifier == "PL.Header" ? header
                : PageLookup.ancestor(of: header, id: "PL.Header") ?? header
            if nativeHeader !== hero {
                nativeHeader?.alpha = headerAlpha
                nativeHeader = hero; headerAlpha = hero.alpha
            }
            hero.alpha = 0
            let labels = GlassPlaylist.collect(UILabel.self, in: header).filter { !($0.text ?? "").isEmpty }
            guard let headline = labels.max(by: { $0.font.pointSize < $1.font.pointSize }) else { return }
            title.text = headline.text
            let details = labels.filter {
                $0 !== headline && (3..<80).contains($0.text?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0)
                    && $0.font.pointSize < headline.font.pointSize
                    && $0.text?.lowercased() != headline.text?.lowercased()
                    && !["play", "pause", "shuffle", "follow", "find on this page"].contains($0.text?.lowercased() ?? "")
            }.sorted { $0.font.pointSize > $1.font.pointSize }
            var text = [String]()
            for label in details {
                if let value = label.text, !text.contains(value) { text.append(value) }
                if text.count == 2 { break }
            }
            summary.text = text.joined(separator: "\n")
        }
        func bind(_ row: PlaylistActionRow, header: UIView) {
            actions = row
            row.compactLayout = true; row.alpha = 1
            sources = [row.play, row.shuffle, row.add, row.share, row.followControl, row.download].compactMap { $0 }
            targets = sources.compactMap { ($0 as? UIControl) ?? $0.eeveeFirst(UIControl.self) }
                .flatMap { $0.allTargets.map { $0.base as AnyObject } }
            if row.superview !== sidebar { sidebar.addSubview(row) }
            metadata(header)
            apply()
        }
        func apply() {
            guard visible, let root, let window = root.window,
                  window.bounds.width > window.bounds.height, let scroll else { return }
            LandscapeNavigation.setPlaylist(root, visible: true)
            let safe = window.safeAreaLayoutGuide.layoutFrame
            let top = max(8, safe.minY + 8)
            let bottom = LandscapeNavigation.contentBottom(in: window)
            let left = safe.minX + 8
            let width = max(180, min(208, (LandscapeNavigation.contentRight(in: window) - left) * 0.25))
            let right = left + width + 16
            let column = CGRect(x: right, y: top, width: max(1, LandscapeNavigation.contentRight(in: window) - right), height: max(1, bottom - top))
            // UIKit retains ownership of the controller root during navigation transitions.
            list?.place(column, in: window)
            if scroll.contentInsetAdjustmentBehavior != .never { scroll.contentInsetAdjustmentBehavior = .never }
            // PL.Header is a sibling overlay, not a collection cell. Its old inset still reserves the entire hero.
            let offset = scroll.contentOffset
            var compactInsets = scroll.contentInset
            compactInsets.top = 0; compactInsets.bottom = 0
            if scroll.contentInset != compactInsets {
                scroll.contentInset = compactInsets
                scroll.verticalScrollIndicatorInsets = .zero
                scroll.contentOffset = CGPoint(x: offset.x, y: max(0, offset.y))
            }
            nativeHeader?.alpha = 0
            if scroll.backgroundColor != root.backgroundColor { scroll.backgroundColor = root.backgroundColor }
            if sidebar.superview !== root { root.addSubview(sidebar) }
            sidebar.frame = root.convert(CGRect(x: left, y: top, width: width, height: column.height), from: window)
            cover.frame = CGRect(x: 0, y: 0, width: 112, height: 112)
            let titleHeight = min(44, title.sizeThatFits(CGSize(width: width, height: 100)).height)
            title.frame = CGRect(x: 0, y: 120, width: width, height: titleHeight)
            summary.frame = CGRect(x: 0, y: title.frame.maxY + 4, width: width, height: 32)
            let actionY = summary.frame.maxY + 10
            if let actions { actions.frame = CGRect(x: 0, y: actionY, width: width, height: actions.compactHeight) }
            sidebar.contentSize = CGSize(width: width, height: actionY + (actions?.compactHeight ?? 0) + 8)
            if let controller = root.next as? UIViewController { dock.layout(controller, in: window, host: root) }

        }
    }

    private final class Header {
        let artwork: NativeViewPlacement
        let column: NativeViewPlacement
        let toolbar: NativeViewPlacement?
        let artworkWasHidden: Bool
        let artworkAlpha: CGFloat
        let columnAlpha: CGFloat
        let toolbarAlpha: CGFloat?
        let clips: Bool
        weak var header: UIView?
        weak var pageRoot: UIView?
        var fittedHeight: CGFloat = 0
        init(header: UIView, artwork: UIView, column: UIView, toolbar: UIView?, pageRoot: UIView?) {
            self.header = header; clips = header.clipsToBounds
            columnAlpha = column.alpha; toolbarAlpha = toolbar?.alpha
            artworkWasHidden = artwork.isHidden; artworkAlpha = artwork.alpha
            self.artwork = NativeViewPlacement(artwork); self.column = NativeViewPlacement(column)
            self.toolbar = toolbar.map(NativeViewPlacement.init); self.pageRoot = pageRoot
        }
        func restore() {
            artwork.view?.isHidden = artworkWasHidden
            artwork.view?.alpha = artworkAlpha
            column.view?.alpha = columnAlpha
            if let toolbarAlpha { toolbar?.view?.alpha = toolbarAlpha }
            header?.clipsToBounds = clips
            artwork.restore(); column.restore(); toolbar?.restore()
        }
    }

    static func isLandscape(_ view: UIView) -> Bool {
        guard let window = view.window else { return false }
        return window.bounds.width > window.bounds.height
    }

    private static func pageRoot(for view: UIView) -> UIView? {
        var current: UIView? = view
        while let node = current {
            if objc_getAssociatedObject(node, &pageKey) is Page { return node }
            if let root = (objc_getAssociatedObject(node, &pageRootKey) as? PageLookup.WeakView)?.view { return root }
            current = node.superview
        }
        return nil
    }

    static func layoutPage(_ root: UIView, list: UIScrollView?, header: UIView?) {
        guard !updating else { return }
        updating = true; defer { updating = false }
        let old = objc_getAssociatedObject(root, &pageKey) as? Page
        guard isLandscape(root), let list else {
            old?.restore(); objc_setAssociatedObject(root, &pageKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        let page: Page
        if let old, old.scroll === list { page = old }
        else {
            old?.restore(); page = Page(root: root, list: list)
            objc_setAssociatedObject(root, &pageKey, page, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            pages.add(root)
        }
        if let header { page.metadata(header) }
        if let artwork = header.flatMap({ PageLookup.find("Components.Header.UI.ArtworkImage", in: $0) }) {
            // The shadow texture is also a UIImageView. Prefer the actual square artwork.
            var candidates = [UIImageView]()
            func collect(_ view: UIView) {
                if let image = view as? UIImageView, image.bounds.width > 40,
                   image.bounds.height > image.bounds.width * 0.75 { candidates.append(image) }
                view.subviews.forEach(collect)
            }
            collect(artwork)
            page.track(candidates)
        }
        page.apply()
    }

    static func setVisible(_ root: UIView?, _ visible: Bool) {
        guard let root, let page = objc_getAssociatedObject(root, &pageKey) as? Page else { return }
        page.visible = visible
        if visible { page.apply() }
        else {
            page.suspend()
            LandscapeNavigation.setPlaylist(root, visible: false)
        }
    }

    static func listDidLayout(_ list: UIScrollView) {
        guard !updating, let root = pageRoot(for: list), isLandscape(root),
              let page = objc_getAssociatedObject(root, &pageKey) as? Page else { return }
        updating = true; defer { updating = false }
        page.apply()
    }

    private static func contentLayout(in view: UIView) -> UIView? {
        if NSStringFromClass(type(of: view)).hasSuffix("HeaderContentLayout") { return view }
        return view.eeveeFirst(UIView.self, where: { NSStringFromClass(type(of: $0)).hasSuffix("HeaderContentLayout") })
    }

    static func width(in view: UIView) -> CGFloat? {
        let storedRoot = contentLayout(in: view).flatMap { (objc_getAssociatedObject($0, &headerKey) as? Header)?.pageRoot }
        guard let root = pageRoot(for: view) ?? storedRoot, isLandscape(root),
              let page = objc_getAssociatedObject(root, &pageKey) as? Page, let scroll = page.scroll,
              scroll.bounds.width > 0 else { return nil }
        return min(root.bounds.width, scroll.bounds.width)
    }

    static func height(in view: UIView) -> CGFloat? {
        guard let layout = contentLayout(in: view), let state = objc_getAssociatedObject(layout, &headerKey) as? Header,
              let window = view.window ?? state.pageRoot?.window, window.bounds.width > window.bounds.height,
              state.fittedHeight > 0 else { return nil }
        return state.fittedHeight
    }

    static func prepare(_ header: UIView) {
        guard !isLandscape(header), let state = objc_getAssociatedObject(header, &headerKey) as? Header else { return }
        state.restore(); objc_setAssociatedObject(header, &headerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func layout(_ header: UIView) {
        guard !updating, isLandscape(header), let image = PageLookup.find("Components.Header.UI.ArtworkImage", in: header) else { return }
        updating = true; defer { updating = false }
        let anchor = PageLookup.find("Components.Header.UI.Metadata", in: header)
            ?? header.eeveeFirst(UILabel.self, where: { !$0.isHidden && !($0.text ?? "").isEmpty && !$0.isDescendant(of: image) })
        guard var column = anchor else { return }
        while let parent = column.superview, parent !== header, !image.isDescendant(of: parent) { column = parent }
        guard column !== header, !image.isDescendant(of: column) else { return }
        // Ancestors can also own the playback toolbar. Suppress only the image component.
        let artwork = image
        var toolbar = header.eeveeFirst(UIView.self, where: { $0.accessibilityIdentifier == "header-play-button" })
        while let node = toolbar, let parent = node.superview, parent !== header,
              !column.isDescendant(of: parent), !artwork.isDescendant(of: parent) { toolbar = parent }
        if toolbar?.isDescendant(of: column) == true || toolbar === column { toolbar = nil }
        let old = objc_getAssociatedObject(header, &headerKey) as? Header
        let state: Header
        if let old, old.artwork.view === artwork, old.column.view === column, old.toolbar?.view === toolbar { state = old }
        else {
            old?.restore(); state = Header(header: header, artwork: artwork, column: column, toolbar: toolbar, pageRoot: pageRoot(for: header))
            objc_setAssociatedObject(header, &headerKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC); headers.add(header)
        }
        if state.pageRoot == nil { state.pageRoot = pageRoot(for: header) }
        // Keep the native image loader alive while its visible image is mirrored at the side.
        if artwork.isHidden { artwork.isHidden = false }
        if artwork.alpha != 0 { artwork.alpha = 0 }
        if image.alpha != 0 { image.alpha = 0 }
        if let stack = artwork.superview as? UIStackView, stack.arrangedSubviews.contains(artwork) { stack.removeArrangedSubview(artwork) }
        state.column.view?.alpha = 0
        state.toolbar?.view?.alpha = 0
        header.clipsToBounds = true
        let total: CGFloat = 1
        if abs(state.fittedHeight - total) > 0.5 {
            state.fittedHeight = total
            var ancestor = header.superview
            while let node = ancestor {
                if let collection = node as? UICollectionView {
                    DispatchQueue.main.async { [weak collection] in collection?.collectionViewLayout.invalidateLayout() }
                    break
                }
                ancestor = node.superview
            }
        }
        if let root = state.pageRoot, let page = objc_getAssociatedObject(root, &pageKey) as? Page {
            page.metadata(header)
        }
    }

    static func hostActions(_ row: PlaylistActionRow, in root: UIView, header: UIView) -> Bool {
        guard !updating else { return row.compactLayout }
        updating = true; defer { updating = false }
        guard isLandscape(root), let page = objc_getAssociatedObject(root, &pageKey) as? Page, page.visible else {
            row.compactLayout = false
            return false
        }
        page.bind(row, header: header)
        return true
    }

    static func pointInside(_ view: UIView) -> Bool? {
        guard isLandscape(view) else { return nil }
        for root in pages.allObjects {
            if let page = objc_getAssociatedObject(root, &pageKey) as? Page, page.visible, page.dock.hasControls, page.dock.bar === view { return false }
        }
        return nil
    }

    static func navigationDidLayout(_ bar: UINavigationBar) {
        guard isLandscape(bar) else { return }
        for root in pages.allObjects {
            guard let page = objc_getAssociatedObject(root, &pageKey) as? Page, page.visible, page.dock.bar === bar else { continue }
            bar.alpha = 0
            bar.isHidden = true
        }
    }

    static func nativeHit(at point: CGPoint, in window: UIWindow, event: UIEvent?) -> UIView? {
        guard window.bounds.width > window.bounds.height else { return nil }
        for root in pages.allObjects where root.window === window {
            guard let page = objc_getAssociatedObject(root, &pageKey) as? Page, page.visible else { continue }
            if let hit = page.dock.hit(at: point, in: window, event: event) { return hit }
            if let hit = NativeHitRouter.hit(page.sidebar, at: point, in: window, event: event) { return hit }
        }
        for header in headers.allObjects where header.window === window {
            guard let state = objc_getAssociatedObject(header, &headerKey) as? Header,
                  let pageRoot = state.pageRoot, let page = objc_getAssociatedObject(pageRoot, &pageKey) as? Page, page.visible,
                  let list = page.scroll, list.convert(list.bounds, to: window).contains(point) else { continue }
            for root in [state.toolbar?.view, state.column.view].compactMap({ $0 }) {
                if let hit = NativeHitRouter.hit(root, at: point, in: window, event: event) { return hit }
            }
        }
        return nil
    }
}

class LandscapePlaylistNavigationBarHook: ClassHook<UINavigationBar> {
    typealias Group = GlassPlaylistGroup
    func layoutSubviews() {
        orig.layoutSubviews()
        if #available(iOS 26.0, *) { LandscapePlaylistHeader.navigationDidLayout(target) }
    }
}

class LandscapePlaylistHeaderSizingHook: ClassHook<UICollectionViewCell> {
    typealias Group = GlassPlaylistGroup
    static let targetName = PlaylistPillsCellHook.targetName
    func preferredLayoutAttributesFittingAttributes(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let result = orig.preferredLayoutAttributesFittingAttributes(attributes)
        if #available(iOS 26.0, *), let width = LandscapePlaylistHeader.width(in: target) {
            result.size.width = width
            if PlaylistChips.toolbar(in: target) != nil, GlassPlaylist.row(near: target)?.curation.hasActions == true {
                result.size.height = 1
            }
        }
        if #available(iOS 26.0, *), let height = LandscapePlaylistHeader.height(in: target),
           target.eeveeFirst(UIView.self, where: { $0.accessibilityIdentifier == "PL.Header" }) != nil {
            result.size = CGSize(width: result.size.width, height: height)
        }
        return result
    }
}
