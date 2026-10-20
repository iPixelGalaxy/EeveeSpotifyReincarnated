import UIKit

/// A native segmented control supplies the system's tracking, refraction and spring animation.
@available(iOS 26.0, *)
final class LandscapeNavigationRail: UIView {
    private final class HoverMonitor: UIGestureRecognizer {
        var moved: ((UITouch) -> Void)?
        var finished: ((Bool) -> Void)?
        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        }
        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first { moved?(touch) }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first { moved?(touch) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            finished?(true); state = .failed
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            finished?(false); state = .failed
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
    private let segments = UISegmentedControl(items: nil)
    private var hoverActive = false
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
        let monitor = HoverMonitor()
        monitor.moved = { [weak self] touch in
            guard let self, !items.isEmpty else { return }
            hoverActive = true
            let fraction = touch.location(in: segments).x / max(1, segments.bounds.width)
            preview(min(items.count - 1, max(0, Int(fraction * CGFloat(items.count)))))
        }
        monitor.finished = { [weak self] committed in
            // UIKit completes its own selection after passive recognizers receive the ending touch.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                hoverActive = false
                if committed { _ = commit(segments.selectedSegmentIndex) }
                else if let model { update(model); preview(segments.selectedSegmentIndex) }
                renderImages()
            }
        }
        segments.addGestureRecognizer(monitor)
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
        if !hoverActive {
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
        let font = UIFont.systemFont(ofSize: 10, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let labelHeight = item.title.map {
            min(ceil(font.lineHeight * 2), ceil(($0 as NSString).boundingRect(
                with: CGSize(width: imageSize.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil).height))
        } ?? 0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: imageSize.height, height: imageSize.width))
        let image = renderer.image { context in
            let drawing = context.cgContext
            drawing.translateBy(x: imageSize.height / 2, y: imageSize.width / 2)
            drawing.rotate(by: -.pi / 2)
            drawing.translateBy(x: -imageSize.width / 2, y: -imageSize.height / 2)
            let icon: CGFloat = 23
            let gap: CGFloat = labelHeight > 0 ? 4 : 0
            let top = max(0, (imageSize.height - icon - gap - labelHeight) / 2)
            symbol?.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: CGRect(x: (imageSize.width - icon) / 2, y: top, width: icon, height: icon))
            if let title = item.title {
                (title as NSString).draw(with: CGRect(x: 0, y: top + icon + gap, width: imageSize.width, height: labelHeight),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
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
        preview(index)
        return true
    }

    @objc private func selectionChanged() {
        if !hoverActive { _ = commit(segments.selectedSegmentIndex) }
    }
}
