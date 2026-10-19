import UIKit

/// A native segmented control supplies the system's tracking, refraction and spring animation.
@available(iOS 26.0, *)
final class LandscapeNavigationRail: UIView {
    private final class Segments: UISegmentedControl {
        var hover: ((Int) -> Void)?
        var finish: (() -> Void)?
        private func preview(_ touch: UITouch) {
            guard numberOfSegments > 0 else { return }
            let x = touch.location(in: self).x
            hover?(min(numberOfSegments - 1, max(0, Int(x / max(1, bounds.width) * CGFloat(numberOfSegments)))))
        }
        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            let tracking = super.beginTracking(touch, with: event)
            if tracking { preview(touch) }
            return tracking
        }
        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            let tracking = super.continueTracking(touch, with: event)
            if tracking { preview(touch) }
            return tracking
        }
        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            super.endTracking(touch, with: event)
            finish?()
        }
        override func cancelTracking(with event: UIEvent?) {
            super.cancelTracking(with: event)
            hover?(selectedSegmentIndex)
        }
    }
    private final class TabAccessibility: UIAccessibilityElement {
        weak var rail: LandscapeNavigationRail?
        let index: Int
        init(rail: LandscapeNavigationRail, index: Int) {
            self.rail = rail; self.index = index
            super.init(accessibilityContainer: rail)
        }
        override func accessibilityActivate() -> Bool { rail?.commit(index) ?? false }
    }
    private weak var model: GlassSystemTabBar?
    private let segments = Segments(items: nil)
    private var items = [Item]()
    private var tint = UIColor.systemGreen
    private var previewIndex = 0
    private var imageSize = CGSize.zero
    private struct Item: Equatable {
        let title: String?
        let image: UIImage?
        let selectedImage: UIImage?
        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.title == rhs.title && lhs.image === rhs.image && lhs.selectedImage === rhs.selectedImage
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        segments.transform = CGAffineTransform(rotationAngle: .pi / 2)
        segments.accessibilityElementsHidden = true
        segments.addTarget(self, action: #selector(selectionChanged), for: .valueChanged)
        segments.hover = { [weak self] index in self?.preview(index) }
        segments.finish = { [weak self] in
            guard let self else { return }
            _ = commit(segments.selectedSegmentIndex)
        }
        addSubview(segments)
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: bounds.height, height: bounds.width)
        if segments.bounds.size != size { segments.bounds.size = size }
        segments.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let nextSize = CGSize(width: max(1, bounds.width - 12), height: max(1, bounds.height / CGFloat(max(1, items.count)) - 8))
        if imageSize != nextSize {
            imageSize = nextSize
            renderImages()
        }
        if let elements = accessibilityElements as? [TabAccessibility] {
            let height = bounds.height / CGFloat(max(1, items.count))
            for element in elements { element.accessibilityFrameInContainerSpace = CGRect(x: 0, y: CGFloat(element.index) * height, width: bounds.width, height: height) }
        }
    }

    func update(_ bar: GlassSystemTabBar) {
        model = bar
        let next = (bar.items ?? []).map { Item(title: $0.title, image: $0.image, selectedImage: $0.selectedImage) }
        let selected = bar.items?.firstIndex(where: { $0 === bar.selectedItem }) ?? 0
        let changed = items != next || tint != bar.tintColor
        if items.count != next.count {
            segments.removeAllSegments()
            for index in next.indices { segments.insertSegment(with: UIImage(), at: index, animated: false) }
            accessibilityElements = next.indices.map { TabAccessibility(rail: self, index: $0) }
            setNeedsLayout()
        }
        items = next; tint = bar.tintColor
        if !segments.isTracking {
            let selectionChanged = segments.selectedSegmentIndex != selected
            if selectionChanged { segments.selectedSegmentIndex = selected }
            if changed || selectionChanged { previewIndex = selected; renderImages() }
        } else if changed { renderImages() }
        if let elements = accessibilityElements as? [TabAccessibility] {
            for element in elements {
                element.accessibilityLabel = items[element.index].title
                element.accessibilityTraits = element.index == selected ? [.button, .selected] : .button
            }
        }
    }

    private func preview(_ index: Int) {
        guard items.indices.contains(index), previewIndex != index else { return }
        let previous = previewIndex; previewIndex = index
        for position in [previous, index] where items.indices.contains(position) { renderImage(at: position) }
    }

    private func renderImages() {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        for index in items.indices { renderImage(at: index) }
    }

    private func renderImage(at index: Int) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let item = items[index]
        let selected = index == previewIndex
        let color: UIColor = selected ? tint : .white
        let symbol = selected ? item.selectedImage ?? item.image : item.image
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: imageSize.height, height: imageSize.width))
        let image = renderer.image { context in
            let drawing = context.cgContext
            drawing.translateBy(x: imageSize.height / 2, y: imageSize.width / 2)
            drawing.rotate(by: -.pi / 2)
            drawing.translateBy(x: -imageSize.width / 2, y: -imageSize.height / 2)
            let icon: CGFloat = 23
            let top = max(0, (imageSize.height - icon - 18) / 2)
            symbol?.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: CGRect(x: (imageSize.width - icon) / 2, y: top, width: icon, height: icon))
            if let title = item.title {
                let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
                (title as NSString).draw(in: CGRect(x: 0, y: top + icon + 4, width: imageSize.width, height: 16),
                                         withAttributes: [.font: UIFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: color, .paragraphStyle: paragraph])
            }
        }
        segments.setImage(image.withRenderingMode(.alwaysOriginal), forSegmentAt: index)
    }

    @discardableResult private func commit(_ index: Int) -> Bool {
        guard let model, let tabs = model.items, tabs.indices.contains(index) else { return false }
        if model.selectedItem !== tabs[index] {
            model.selectedItem = tabs[index]
            model.tabBar(model, didSelect: tabs[index])
        }
        update(model)
        return true
    }

    @objc private func selectionChanged() {
        if !segments.isTracking { _ = commit(segments.selectedSegmentIndex) }
    }
}
