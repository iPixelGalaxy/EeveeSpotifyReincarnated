import UIKit

/// Spotify lyrics microphone, drawn from the supplied 16-point SVG path.
enum SpotifyLyricsIcon {
    static func image(size: CGFloat = 22) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { renderer in
            let context = renderer.cgContext
            context.scaleBy(x: size / 16, y: size / 16)
            context.setFillColor(UIColor.white.cgColor)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 13.426000000, y: 2.574000000))
            path.addArc(center: CGPoint(x: 11.423778009, y: 4.575416524), radius: 2.831000000, startAngle: -0.785196980, endAngle: -2.981454297, clockwise: true)
            path.addLine(to: CGPoint(x: 11.876000000, y: 7.371000000))
            path.addArc(center: CGPoint(x: 11.424583476, y: 4.576221991), radius: 2.831000000, startAngle: 1.410657970, endAngle: -0.785599347, clockwise: true)
            path.move(to: CGPoint(x: 10.500000000, y: 8.118000000))
            path.addLine(to: CGPoint(x: 7.881000000, y: 5.498000000))
            path.addLine(to: CGPoint(x: 4.740000000, y: 9.075000000))
            path.addLine(to: CGPoint(x: 2.065000000, y: 12.120000000))
            path.addArc(center: CGPoint(x: 3.033995902, y: 12.967004098), radius: 1.287000000, startAngle: -2.423269819, endAngle: 0.852473492, clockwise: true)
            path.addLine(to: CGPoint(x: 6.941000000, y: 11.248000000))
            path.addLine(to: CGPoint(x: 10.501000000, y: 8.119000000))
            path.closeSubpath()
            path.move(to: CGPoint(x: 7.120000000, y: 4.094000000))
            path.addArc(center: CGPoint(x: 11.424107401, y: 4.575892599), radius: 4.331000000, startAngle: -3.030095888, endAngle: 1.459299561, clockwise: false)
            path.addLine(to: CGPoint(x: 7.932000000, y: 12.373000000))
            path.addLine(to: CGPoint(x: 4.872000000, y: 15.062000000))
            path.addArc(center: CGPoint(x: 3.034194405, y: 12.966805595), radius: 2.787000000, startAngle: 0.850748354, endAngle: -2.421544681, clockwise: false)
            path.addLine(to: CGPoint(x: 3.615000000, y: 8.084000000))
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
        }.withRenderingMode(.alwaysTemplate)
    }
}
