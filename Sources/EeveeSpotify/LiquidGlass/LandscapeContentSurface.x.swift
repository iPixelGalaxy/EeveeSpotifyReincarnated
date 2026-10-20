import Orion
import UIKit

// Orion generates hook registration only for .x.swift files.
class LandscapeContentSurfaceHook: ClassHook<UIView> {
    typealias Group = GlassTabBarGroup
    static let targetName = "_TtC19MainUI_TabBarUIImplP33_FD252D04A07ACEB7AD27A83269E8CFAF19TouchForwardingView"

    func layoutSubviews() {
        orig.layoutSubviews()
        if #available(iOS 26.0, *) { LandscapeNavigation.layoutContentSurface(in: target) }
    }
}

class LandscapeContentFrameHook: ClassHook<UIView> {
    typealias Group = GlassTabBarGroup
    func setFrame(_ frame: CGRect) {
        if #available(iOS 26.0, *) { orig.setFrame(LandscapeNavigation.surfaceFrame(frame, for: target)) }
        else { orig.setFrame(frame) }
    }
}
