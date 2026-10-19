import UIKit

@available(iOS 26.0, *)
final class LandscapeNavigationRail: UIView {
    private weak var model: GlassSystemTabBar?
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var buttons = [UIButton]()
    private struct Item: Equatable {
        let title: String?
        let image: UIImage?
        let selected: Bool
        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.title == rhs.title && lhs.image === rhs.image && lhs.selected == rhs.selected
        }
    }
    private var rendered = [Item]()
    private var renderedTint: UIColor?


    override init(frame: CGRect) {
        super.init(frame: frame)
        let glass = GlassKit.pane(in: self)
        let effect = UIGlassEffect(style: .clear)
        effect.isInteractive = true
        glass.effect = effect
        glass.cornerConfiguration = .capsule()
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 4; stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.first?.frame = bounds
        scroll.frame = bounds.insetBy(dx: 6, dy: 6)
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
        if buttons.count != items.count {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = items.indices.map { index in
                let button = UIButton(type: .system)
                button.tag = index
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
                button.addTarget(self, action: #selector(selectTab(_:)), for: .touchUpInside)
                stack.addArrangedSubview(button)
                return button
            }
        }
        for (button, item) in zip(buttons, items) {
            let selected = bar.selectedItem === item
            var configuration = UIButton.Configuration.glass()
            configuration.cornerStyle = .capsule
            configuration.title = item.title
            configuration.image = selected ? item.selectedImage ?? item.image : item.image
            configuration.imagePlacement = .top; configuration.imagePadding = 3
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 1, bottom: 4, trailing: 1)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes; attributes.font = .systemFont(ofSize: 11, weight: .medium); return attributes
            }
            configuration.baseForegroundColor = selected ? bar.tintColor : .white
            configuration.baseBackgroundColor = selected ? bar.tintColor.withAlphaComponent(0.15) : .clear
            button.configuration = configuration
            button.accessibilityLabel = item.title
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    @objc private func selectTab(_ sender: UIButton) {
        guard let model, let items = model.items, items.indices.contains(sender.tag) else { return }
        let item = items[sender.tag]
        model.selectedItem = item
        update(model)
        model.tabBar(model, didSelect: item)
    }
}
