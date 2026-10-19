import Orion
import UIKit

@available(iOS 26.0, *)
enum LandscapePlaylistHeader {
    private static var headerKey: UInt8 = 0
    private static var pageKey: UInt8 = 0
    private static var pageRootKey: UInt8 = 0
    private static let headers = NSHashTable<UIView>.weakObjects()
    private static var updating = false

    private final class Page {
        weak var root: UIView?
        weak var scroll: UIScrollView?
        let viewport: NativeViewPlacement
        let list: NativeViewPlacement?
        let cover = UIImageView()
        private var coverObservations = [NSKeyValueObservation]()
        private let coverSources = NSHashTable<UIImageView>.weakObjects()
        let inset: UIEdgeInsets
        let indicators: UIEdgeInsets
        let adjustment: UIScrollView.ContentInsetAdjustmentBehavior
        let clips: Bool
        var visible = true
        init(root: UIView, list: UIScrollView) {
            self.root = root; scroll = list; viewport = NativeViewPlacement(root)
            self.list = root === list ? nil : NativeViewPlacement(list)
            inset = list.contentInset; indicators = list.verticalScrollIndicatorInsets
            adjustment = list.contentInsetAdjustmentBehavior
            clips = root.clipsToBounds
            cover.contentMode = .scaleAspectFill; cover.clipsToBounds = true
            cover.layer.cornerRadius = 10; cover.layer.cornerCurve = .continuous
            cover.isAccessibilityElement = true; cover.accessibilityTraits = .image
            cover.accessibilityLabel = "Playlist cover"
            (root.next as? UIViewController)?.traitOverrides.verticalSizeClass = .regular
            (root.next as? UIViewController)?.traitOverrides.horizontalSizeClass = .compact
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
            list?.restore(); viewport.restore()
            root?.clipsToBounds = clips
            (root?.next as? UIViewController)?.traitOverrides.remove(UITraitVerticalSizeClass.self)
            (root?.next as? UIViewController)?.traitOverrides.remove(UITraitHorizontalSizeClass.self)
            if let scroll {
                scroll.contentInsetAdjustmentBehavior = adjustment
                scroll.contentInset = inset; scroll.verticalScrollIndicatorInsets = indicators
                if let offset { scroll.contentOffset = offset }
                objc_setAssociatedObject(scroll, &pageRootKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            cover.removeFromSuperview()
        }
        func apply() {
            guard visible, let root, let parent = root.superview, let window = root.window, let scroll else { return }
            let safe = window.safeAreaLayoutGuide.layoutFrame
            var top = safe.minY + 64
            if let controller = root.next as? UIViewController, let bar = controller.navigationController?.navigationBar,
               bar.window === window, !bar.isHidden, bar.bounds.height < window.bounds.height * 0.4 {
                top = max(top, bar.convert(bar.bounds, to: window).maxY + 12)
            }
            let bottom = LandscapeNavigation.contentBottom(in: window)
            let side = max(80, min(250, min(bottom - top, safe.width * 0.30)))
            let left = safe.minX + 8
            let right = left + side + 24
            let column = CGRect(x: right, y: top, width: max(1, LandscapeNavigation.contentRight(in: window) - right), height: max(1, bottom - top))
            // Shrink the controller's viewport too: Spotify must measure this column like portrait.
            viewport.place(column, in: window)
            root.clipsToBounds = true
            list?.place(root.bounds, in: root)
            if visible {
                if cover.superview !== parent { parent.addSubview(cover) }
                cover.frame = parent.convert(CGRect(x: left, y: top, width: side, height: side), from: window)
            } else { cover.removeFromSuperview() }
            // Spotify owns sticky-header and row insets inside this bounded viewport.
        }
    }

    private final class Header {
        let artwork: NativeViewPlacement
        let column: NativeViewPlacement
        let toolbar: NativeViewPlacement?
        let artworkWasHidden: Bool
        let artworkAlpha: CGFloat
        weak var pageRoot: UIView?
        var fittedHeight: CGFloat = 0
        init(artwork: UIView, column: UIView, toolbar: UIView?, pageRoot: UIView?) {
            artworkWasHidden = artwork.isHidden; artworkAlpha = artwork.alpha
            self.artwork = NativeViewPlacement(artwork); self.column = NativeViewPlacement(column)
            self.toolbar = toolbar.map(NativeViewPlacement.init); self.pageRoot = pageRoot
        }
        func restore() {
            artwork.view?.isHidden = artworkWasHidden
            artwork.view?.alpha = artworkAlpha
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
        }
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
        if visible { page.apply() } else { page.cover.removeFromSuperview() }
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
            old?.restore(); state = Header(artwork: artwork, column: column, toolbar: toolbar, pageRoot: pageRoot(for: header))
            objc_setAssociatedObject(header, &headerKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC); headers.add(header)
        }
        if state.pageRoot == nil { state.pageRoot = pageRoot(for: header) }
        // Keep the native image loader alive while its visible image is mirrored at the side.
        if artwork.isHidden { artwork.isHidden = false }
        if artwork.alpha != 0 { artwork.alpha = 0 }
        if image.alpha != 0 { image.alpha = 0 }
        if let stack = artwork.superview as? UIStackView, stack.arrangedSubviews.contains(artwork) { stack.removeArrangedSubview(artwork) }
        let available = Self.width(in: header) ?? header.bounds.width
        if abs(header.bounds.width - available) > 0.5 {
            var frame = header.frame; frame.size.width = available; header.frame = frame
        }
        let width = max(1, available - 32)
        let fitting = column.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let natural = fitting.isFinite && fitting > 8 && fitting < 10000 ? fitting : state.column.originalHeight
        let columnHeight = max(44, natural)
        state.column.place(CGRect(x: 16, y: 12, width: width, height: columnHeight), in: header)
        let toolbarHeight = state.toolbar.map { max(44, $0.originalHeight) } ?? 0
        state.toolbar?.place(CGRect(x: 16, y: columnHeight + 20, width: width, height: toolbarHeight), in: header)
        let total = columnHeight + (state.toolbar == nil ? 24 : toolbarHeight + 32)
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
        column.layoutIfNeeded(); toolbar?.layoutIfNeeded()
        GlassPlaylist.centerTitleBlock(in: header)
    }

    static func nativeHit(at point: CGPoint, in window: UIWindow, event: UIEvent?) -> UIView? {
        guard window.bounds.width > window.bounds.height else { return nil }
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

class LandscapePlaylistHeaderSizingHook: ClassHook<UICollectionViewCell> {
    typealias Group = GlassPlaylistGroup
    static let targetName = PlaylistPillsCellHook.targetName
    func preferredLayoutAttributesFittingAttributes(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let result = orig.preferredLayoutAttributesFittingAttributes(attributes)
        if #available(iOS 26.0, *), let width = LandscapePlaylistHeader.width(in: target) {
            result.size.width = width
        }
        if #available(iOS 26.0, *), let height = LandscapePlaylistHeader.height(in: target),
           target.eeveeFirst(UIView.self, where: { $0.accessibilityIdentifier == "PL.Header" }) != nil {
            result.size = CGSize(width: result.size.width, height: height)
        }
        return result
    }
}
