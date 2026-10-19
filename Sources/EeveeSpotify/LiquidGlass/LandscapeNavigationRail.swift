import UIKit

@available(iOS 26.0, *)
final class LandscapeNavigationRail: UIView {
    private weak var model: GlassSystemTabBar?
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let selection: UIVisualEffectView = {
        let effect = UIGlassEffect(style: .clear)
        effect.isInteractive = true
        let view = UIVisualEffectView(effect: effect)
        view.isUserInteractionEnabled = false
        view.cornerConfiguration = .capsule()
        return view
    }()
    private var buttons = [UIButton]()
    private var selectedIndex = 0
    private var dragging = false
    private var rendered = [Item]()
    private var renderedTint: UIColor?
    private struct Item: Equatable {
        let title: String?
        let image: UIImage?
        let selected: Bool
        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.title == rhs.title && lhs.image === rhs.image && lhs.selected == rhs.selected
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.cornerConfiguration = .capsule()
        glass.isUserInteractionEnabled = false
        addSubview(glass)
        addSubview(selection)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragSelection(_:))))
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        let inner = bounds.insetBy(dx: 5, dy: 6)
        let height = inner.height / CGFloat(max(1, buttons.count))
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: inner.minX, y: inner.minY + CGFloat(index) * height, width: inner.width, height: height)
        }
        if !dragging { moveSelection(to: selectedIndex, animated: false) }
    }

    func update(_ bar: GlassSystemTabBar) {
        model = bar
        let items = bar.items ?? []
        let next = items.map { item in
            let selected = bar.selectedItem === item
            return Item(title: item.title, image: selected ? item.selectedImage ?? item.image : item.image, selected: selected)
        }
        guard next != rendered || renderedTint != bar.tintColor else { return }
        rendered = next; renderedTint = bar.tintColor
        let previousIndex = selectedIndex
        selectedIndex = items.firstIndex(where: { bar.selectedItem === $0 }) ?? 0
        if buttons.count != items.count {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = items.indices.map { index in
                let button = UIButton(type: .system)
                button.tag = index
                button.addTarget(self, action: #selector(selectTab(_:)), for: .touchUpInside)
                addSubview(button)
                return button
            }
            setNeedsLayout()
        }
        for (button, item) in zip(buttons, items) {
            let selected = bar.selectedItem === item
            var configuration = UIButton.Configuration.plain()
            configuration.title = item.title
            configuration.image = selected ? item.selectedImage ?? item.image : item.image
            configuration.imagePlacement = .top; configuration.imagePadding = 3
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes; attributes.font = .systemFont(ofSize: 10, weight: .medium); return attributes
            }
            configuration.baseForegroundColor = selected ? bar.tintColor : .white
            configuration.background = .clear()
            button.configuration = configuration
            button.accessibilityLabel = item.title
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
        if !dragging { moveSelection(to: selectedIndex, animated: previousIndex != selectedIndex) }
    }

    private func moveSelection(to index: Int, animated: Bool) {
        guard buttons.indices.contains(index) else { selection.isHidden = true; return }
        selection.isHidden = false
        let frame = buttons[index].frame.insetBy(dx: 1, dy: 3)
        guard frame.width > 0, frame.height > 0 else { return }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) { self.selection.frame = frame }
        } else { selection.frame = frame }
    }

    @objc private func dragSelection(_ gesture: UIPanGestureRecognizer) {
        guard !buttons.isEmpty else { return }
        let point = gesture.location(in: self)
        let index = buttons.indices.min(by: { abs(buttons[$0].frame.midY - point.y) < abs(buttons[$1].frame.midY - point.y) }) ?? selectedIndex
        switch gesture.state {
        case .began, .changed:
            dragging = true
            selection.layer.removeAllAnimations()
            let frame = buttons[index].frame.insetBy(dx: 1, dy: 3)
            selection.bounds.size = frame.size
            selection.center = CGPoint(x: frame.midX, y: min(buttons.last!.frame.midY, max(buttons[0].frame.midY, point.y)))
        case .ended:
            dragging = false
            commit(index)
            moveSelection(to: selectedIndex, animated: true)
        case .cancelled, .failed:
            dragging = false
            moveSelection(to: selectedIndex, animated: true)
        default: break
        }
    }

    private func commit(_ index: Int) {
        guard let model, let items = model.items, items.indices.contains(index) else { return }
        let item = items[index]
        guard model.selectedItem !== item else { return }
        model.selectedItem = item
        update(model)
        model.tabBar(model, didSelect: item)
    }

    @objc private func selectTab(_ sender: UIButton) { commit(sender.tag) }
}
