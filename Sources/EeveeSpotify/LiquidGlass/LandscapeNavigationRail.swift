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
    private var imageSize = CGSize.zero
    private var images = [(white: UIImage, green: UIImage)]()
    private weak var lens: UIView?
    private var displayLink: CADisplayLink?
    private var lastLensFrame: CGRect?
    private final class ImageTarget {
        weak var view: UIImageView?
        let index: Int
        var painted: UIImage?
        init(_ view: UIImageView, index: Int) { self.view = view; self.index = index }
    }
    private var imageTargets = [ImageTarget]()
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
        monitor.moved = { [weak self] _ in
            guard let self, !items.isEmpty else { return }
            hoverActive = true
        }
        monitor.finished = { [weak self] committed in
            // UIKit completes its own selection after passive recognizers receive the ending touch.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                hoverActive = false
                if committed { _ = commit(segments.selectedSegmentIndex) }
                else if let model { update(model) }
            }
        }
        segments.addGestureRecognizer(monitor)
        addSubview(segments)
    }
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate(); displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(updateLensTint))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

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
            if changed { renderImages() }
            if selectionChanged { lastLensFrame = nil }
        } else if changed { renderImages() }
        if let elements = accessibilityElements as? [TabAccessibility] {
            for element in elements {
                element.accessibilityLabel = items[element.index].title
                element.accessibilityTraits = element.index == selected ? [.button, .selected] : .button
            }
        }
    }

    private func renderImages() {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        images = items.map { item in
            (renderImage(item, color: .white, symbol: item.image),
             renderImage(item, color: tint, symbol: item.selectedImage ?? item.image))
        }
        for index in images.indices { segments.setImage(images[index].white, forSegmentAt: index) }
        imageTargets.removeAll()
        lastLensFrame = nil
    }

    private func renderImage(_ item: Item, color: UIColor, symbol: UIImage?) -> UIImage {
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
        return image.withRenderingMode(.alwaysOriginal)
    }

    @objc private func updateLensTint() {
        guard !images.isEmpty, images.count == segments.numberOfSegments else { return }
        if lens?.isDescendant(of: segments) != true {
            lens = segments.eeveeFirst(UIView.self) { NSStringFromClass(type(of: $0)).contains("_UILiquidLensView") }
        }
        guard let lens, !lens.isHidden, lens.alpha > 0.01 else { return }
        let slot = segments.bounds.width / CGFloat(images.count)
        if imageTargets.isEmpty || imageTargets.contains(where: { $0.view?.isDescendant(of: segments) != true }) {
            imageTargets.removeAll()
            var queue = segments.subviews
            while let view = queue.popLast() {
                if view === lens { continue }
                queue.append(contentsOf: view.subviews)
                guard let image = view as? UIImageView, image.image?.size == images[0].white.size else { continue }
                let x = image.convert(CGPoint(x: image.bounds.midX, y: image.bounds.midY), to: segments).x
                let index = min(images.count - 1, max(0, Int(x / max(1, slot))))
                imageTargets.append(ImageTarget(image, index: index))
            }
        }
        guard !imageTargets.isEmpty else { return }
        let frame: CGRect
        if let source = lens.layer.presentation(), let destination = segments.layer.presentation() {
            frame = source.convert(source.bounds, to: destination)
        } else { frame = lens.convert(lens.bounds, to: segments) }
        guard frame != lastLensFrame || imageTargets.contains(where: { $0.view?.image !== $0.painted }) else { return }
        lastLensFrame = frame
        for target in imageTargets {
            guard let view = target.view, view.bounds.width > 0, view.bounds.height > 0 else { continue }
            let pair = images[target.index]
            let size = pair.white.size
            let local: CGRect
            if let source = lens.layer.presentation(), let destination = view.layer.presentation() {
                local = source.convert(source.bounds, to: destination)
            } else { local = lens.convert(lens.bounds, to: view) }
            let sx = size.width / view.bounds.width, sy = size.height / view.bounds.height
            let clip = CGRect(x: (local.minX - view.bounds.minX) * sx, y: (local.minY - view.bounds.minY) * sy,
                              width: local.width * sx, height: local.height * sy)
            let radius = min(clip.width, clip.height) / 2
            guard clip.intersects(CGRect(origin: .zero, size: size)) else {
                if view.image !== pair.white { view.image = pair.white }
                target.painted = pair.white
                continue
            }
            // Paint underneath UIKit's real moving lens, so its own refraction still applies.
            // Reading the presentation layer follows spring motion and overlap between slots.
            let image = UIGraphicsImageRenderer(size: size).image { context in
                pair.white.draw(at: .zero)
                context.cgContext.addPath(UIBezierPath(roundedRect: clip, cornerRadius: radius).cgPath)
                context.cgContext.clip()
                pair.green.draw(at: .zero)
            }
            // Update only the displayed pixels; changing segment items here restarts native tracking.
            let painted = image.withRenderingMode(.alwaysOriginal)
            view.image = painted
            target.painted = painted
        }
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
        if !hoverActive { _ = commit(segments.selectedSegmentIndex) }
    }
}
