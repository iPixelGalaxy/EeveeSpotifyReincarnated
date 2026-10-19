import Orion
import UIKit

@available(iOS 26.0, *)
private enum LandscapePlaylistRows {
    private static let playlistClass = NSClassFromString(PlaylistListHook.targetName)

    static func fit(_ attributes: UICollectionViewLayoutAttributes, in layout: UICollectionViewLayout) -> UICollectionViewLayoutAttributes {
        guard let collection = layout.collectionView, let playlistClass, collection.isKind(of: playlistClass),
              LandscapePlaylistHeader.isLandscape(collection), attributes.representedElementCategory == .cell,
              collection.bounds.width > 0 else { return attributes }
        let frame = CGRect(x: 0, y: attributes.frame.minY, width: collection.bounds.width, height: attributes.frame.height)
        guard frame != attributes.frame, let result = attributes.copy() as? UICollectionViewLayoutAttributes else { return attributes }
        result.frame = frame
        return result
    }
}

// The native layout centers rows at a readable width. Fit their attributes to the actual landscape column.
// Never change collection offsets, insets or invalidate layout from its own callback.
class LandscapePlaylistRowsHook: ClassHook<UICollectionViewCompositionalLayout> {
    typealias Group = GlassPlaylistGroup

    func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let attributes = orig.layoutAttributesForElements(in: rect)
        guard #available(iOS 26.0, *) else { return attributes }
        return attributes?.map { LandscapePlaylistRows.fit($0, in: target) }
    }

    func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let attributes = orig.layoutAttributesForItem(at: indexPath)
        guard #available(iOS 26.0, *), let attributes else { return attributes }
        return LandscapePlaylistRows.fit(attributes, in: target)
    }
}
