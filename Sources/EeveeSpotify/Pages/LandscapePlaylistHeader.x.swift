import Orion
import UIKit

@available(iOS 26.0, *)
enum LandscapePlaylistHeader {
    private static var stateKey: UInt8 = 0
    private static let headers = NSHashTable<UIView>.weakObjects()
    private static var updating = false

    private final class State {
        let artwork: NativeViewPlacement
        let column: NativeViewPlacement
        let toolbar: NativeViewPlacement?
        let alignments: [(PageLookup.WeakView, NSTextAlignment)]
        init(artwork: UIView, column: UIView, toolbar: UIView?) {
            self.artwork = NativeViewPlacement(artwork)
            self.column = NativeViewPlacement(column)
            self.toolbar = toolbar.map(NativeViewPlacement.init)
            var labels = [UILabel]()
            var queue = [column]
            while !queue.isEmpty {
                let view = queue.removeLast(); queue += view.subviews
                if let label = view as? UILabel { labels.append(label) }
            }
            alignments = labels.map { (PageLookup.WeakView($0), $0.textAlignment) }
            labels.forEach { $0.textAlignment = .left }
        }
        func restore() {
            artwork.restore(); column.restore(); toolbar?.restore()
            for (weakView, alignment) in alignments { (weakView.view as? UILabel)?.textAlignment = alignment }
        }
    }

    static func isLandscape(_ view: UIView) -> Bool {
        guard let window = view.window else { return false }
        return window.bounds.width > window.bounds.height
    }

    static func height(in view: UIView) -> CGFloat? {
        let window = view.window ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.windows.first { $0.isKeyWindow }
        guard let window, window.bounds.width > window.bounds.height else { return nil }
        return min(260, max(220, window.bounds.height * 0.58))
    }

    static func prepare(_ header: UIView) {
        guard !isLandscape(header), let state = objc_getAssociatedObject(header, &stateKey) as? State else { return }
        state.restore()
        objc_setAssociatedObject(header, &stateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func layout(_ header: UIView) {
        guard !updating, isLandscape(header), let height = height(in: header),
              let artwork = PageLookup.find("Components.Header.UI.ArtworkImage", in: header) else { return }
        updating = true
        defer { updating = false }
        let anchor = PageLookup.find("Components.Header.UI.Metadata", in: header)
            ?? header.eeveeFirst(UILabel.self, where: { !$0.isHidden && !($0.text ?? "").isEmpty && !$0.isDescendant(of: artwork) })
        guard var column = anchor else { return }
        while let parent = column.superview, parent !== header, !artwork.isDescendant(of: parent) { column = parent }
        guard column !== header, !artwork.isDescendant(of: column) else { return }

        var toolbar = header.eeveeFirst(UIView.self, where: { $0.accessibilityIdentifier == "header-play-button" })
        while let node = toolbar, let parent = node.superview, parent !== header,
              !column.isDescendant(of: parent), !artwork.isDescendant(of: parent) { toolbar = parent }
        if toolbar?.isDescendant(of: column) == true || toolbar === column { toolbar = nil }

        let old = objc_getAssociatedObject(header, &stateKey) as? State
        let state: State
        if let old, old.artwork.view === artwork, old.column.view === column, old.toolbar?.view === toolbar { state = old }
        else {
            old?.restore()
            state = State(artwork: artwork, column: column, toolbar: toolbar)
            objc_setAssociatedObject(header, &stateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            headers.add(header)
            eeveeLog("[Landscape][Playlist] cover and information in columns")
        }
        let side = min(240, height - 24)
        state.artwork.place(CGRect(x: 12, y: 12, width: side, height: side), in: header)
        if artwork.alpha != 1 { artwork.alpha = 1 }
        let left = side + 36
        let width = max(1, header.bounds.width - left - 16)
        let toolbarHeight: CGFloat = state.toolbar == nil ? 0 : 56
        let columnHeight = min(max(44, state.column.originalHeight), height - 24 - toolbarHeight)
        state.column.place(CGRect(x: left, y: 12, width: width, height: columnHeight), in: header)
        state.toolbar?.place(CGRect(x: left, y: min(height - 68, columnHeight + 20), width: width, height: 56), in: header)
        artwork.layoutIfNeeded(); column.layoutIfNeeded(); toolbar?.layoutIfNeeded()
    }

    static func nativeHit(at point: CGPoint, in window: UIWindow, event: UIEvent?) -> UIView? {
        guard window.bounds.width > window.bounds.height, point.y >= window.safeAreaLayoutGuide.layoutFrame.minY + 44 else { return nil }
        for header in headers.allObjects where header.window === window {
            guard let state = objc_getAssociatedObject(header, &stateKey) as? State else { continue }
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
        if #available(iOS 26.0, *), let height = LandscapePlaylistHeader.height(in: target),
           target.eeveeFirst(UIView.self, where: { $0.accessibilityIdentifier == "PL.Header" }) != nil {
            result.size = CGSize(width: result.size.width, height: height)
        }
        return result
    }
}
