import Orion
import UIKit

@available(iOS 26.0, *)
private enum LandscapePlaylistRows {
    private static let playlistClass = NSClassFromString(PlaylistListHook.targetName)
    static var readingNative = false
    // FTP's track section follows its curation section, including playlists with only one track.
    static let trackSection = 2

    static func native<T>(_ body: () -> T) -> T {
        let previous = readingNative; readingNative = true
        defer { readingNative = previous }
        return body()
    }

    static func isPlaylist(_ layout: UICollectionViewLayout) -> Bool {
        guard let collection = layout.collectionView, let playlistClass else { return false }
        return collection.isKind(of: playlistClass) && LandscapePlaylistHeader.isLandscape(collection)
    }

    static func origin(in layout: UICollectionViewLayout, original: (IndexPath) -> UICollectionViewLayoutAttributes?) -> CGFloat {
        guard let collection = layout.collectionView, collection.numberOfSections > trackSection,
              collection.numberOfItems(inSection: trackSection) > 0 else { return 0 }
        return native { original(IndexPath(item: 0, section: trackSection))?.frame.minY ?? 0 }
    }

    static func fit(_ attributes: UICollectionViewLayoutAttributes, in layout: UICollectionViewLayout, origin: CGFloat) -> UICollectionViewLayoutAttributes {
        guard let collection = layout.collectionView, let playlistClass, collection.isKind(of: playlistClass),
              LandscapePlaylistHeader.isLandscape(collection), attributes.representedElementCategory == .cell,
              collection.bounds.width > 0 else { return attributes }
        let frame = CGRect(x: 0, y: attributes.frame.minY - origin, width: collection.bounds.width, height: attributes.frame.height)
        guard frame != attributes.frame, let result = attributes.copy() as? UICollectionViewLayoutAttributes else { return attributes }
        result.frame = frame
        return result
    }
}

// The native layout centers rows at a readable width. Fit their attributes to the actual landscape column.
// Never change collection offsets, insets or invalidate layout from its own callback.
class LandscapePlaylistRowsHook: ClassHook<UICollectionViewLayout> {
    typealias Group = GlassPlaylistGroup
    static let targetName = "_TtC24ListUXPlatform_LayoutKit10ListLayout"

    @objc(layoutAttributesForElementsInRect:)
    func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard #available(iOS 26.0, *), !LandscapePlaylistRows.readingNative, LandscapePlaylistRows.isPlaylist(target) else {
            return orig.layoutAttributesForElements(in: rect)
        }
        let origin = LandscapePlaylistRows.origin(in: target) { orig.layoutAttributesForItem(at: $0) }
        let attributes = LandscapePlaylistRows.native { orig.layoutAttributesForElements(in: rect.offsetBy(dx: 0, dy: origin)) }
        return attributes?.map { LandscapePlaylistRows.fit($0, in: target, origin: origin) }
    }

    @objc(layoutAttributesForItemAtIndexPath:)
    func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let attributes = orig.layoutAttributesForItem(at: indexPath)
        guard #available(iOS 26.0, *), !LandscapePlaylistRows.readingNative,
              LandscapePlaylistRows.isPlaylist(target), let attributes else { return attributes }
        let origin = LandscapePlaylistRows.origin(in: target) { orig.layoutAttributesForItem(at: $0) }
        return LandscapePlaylistRows.fit(attributes, in: target, origin: origin)
    }
}
