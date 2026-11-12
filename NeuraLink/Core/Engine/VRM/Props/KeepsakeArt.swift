//
//  KeepsakeArt.swift
//  NeuraLink
//
//  The pictures painted onto the keepsake props: a place card, a notebook
//  cover, a record sleeve, a blank polaroid, the pips of a die, a leaf and
//  a flower. CoreGraphics into PNG bytes, decoded into mipmapped textures
//  by VRMPropTextureDecoder like any prop image. The objects cover a
//  hundred-odd pixels on screen, so the images stay small.
//
//  Created by Dedicatus on 05/11/2026.
//

import UIKit

enum KeepsakeArt {

    static let side: CGFloat = 256

    // MARK: - Pictures

    /// A cream place card: "First hello" over the date.
    static func card(date: String) -> Data {
        paint(size: CGSize(width: side, height: side * 0.66)) { context, bounds in
            fill(context, bounds, UIColor(red: 0.98, green: 0.95, blue: 0.88, alpha: 1))
            context.setStrokeColor(UIColor(red: 0.80, green: 0.70, blue: 0.52, alpha: 1).cgColor)
            context.setLineWidth(3)
            context.stroke(bounds.insetBy(dx: 10, dy: 10))
            draw("FIRST HELLO", in: CGRect(x: 0, y: bounds.height * 0.22, width: bounds.width, height: 30),
                 font: .systemFont(ofSize: 20, weight: .semibold), colour: UIColor(white: 0.45, alpha: 1))
            draw(date, in: CGRect(x: 0, y: bounds.height * 0.46, width: bounds.width, height: 50),
                 font: rounded(44, weight: .bold), colour: UIColor(red: 0.30, green: 0.22, blue: 0.14, alpha: 1))
        }
    }

    /// A dark notebook cover with a lighter band and the character's name.
    static func notebook(name: String) -> Data {
        paint(size: CGSize(width: side * 0.73, height: side)) { context, bounds in
            fill(context, bounds, UIColor(red: 0.16, green: 0.30, blue: 0.32, alpha: 1))
            fill(context, CGRect(x: 0, y: bounds.height * 0.40, width: bounds.width, height: bounds.height * 0.14),
                 UIColor(red: 0.92, green: 0.86, blue: 0.70, alpha: 1))
            draw("Diary", in: CGRect(x: 0, y: bounds.height * 0.41, width: bounds.width, height: 34),
                 font: rounded(28, weight: .bold), colour: UIColor(red: 0.16, green: 0.30, blue: 0.32, alpha: 1))
            draw(name, in: CGRect(x: 0, y: bounds.height * 0.80, width: bounds.width, height: 26),
                 font: rounded(18, weight: .medium), colour: UIColor(white: 0.9, alpha: 1))
        }
    }

    /// A record sleeve: a hue from the title, a faint note, title and artist.
    static func sleeve(title: String, artist: String) -> Data {
        paint(size: CGSize(width: side, height: side)) { context, bounds in
            // FNV-1a over the title: `hashValue` is seeded per launch and
            // would recolour the sleeve every time the app starts.
            let hash = title.utf8.reduce(UInt64(2_166_136_261)) { ($0 ^ UInt64($1)) &* 16_777_619 }
            let hue = CGFloat(hash % 360) / 360
            let top = UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
            let bottom = UIColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.45, alpha: 1)
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: bounds.height), options: [])
            }
            draw("\u{266A}", in: CGRect(x: 0, y: bounds.height * 0.08, width: bounds.width, height: 130),
                 font: .systemFont(ofSize: 120, weight: .bold), colour: UIColor(white: 1, alpha: 0.25))
            let shownTitle = title.isEmpty ? "Our song" : title
            draw(shownTitle, in: CGRect(x: 16, y: bounds.height * 0.58, width: bounds.width - 32, height: 64),
                 font: rounded(26, weight: .bold), colour: .white, lines: 2)
            draw(artist, in: CGRect(x: 16, y: bounds.height * 0.84, width: bounds.width - 32, height: 26),
                 font: rounded(18, weight: .medium), colour: UIColor(white: 1, alpha: 0.85))
        }
    }

    /// A polaroid that holds no picture: a soft sky with a sun.
    static func blankPolaroid() -> Data {
        paint(size: CGSize(width: side, height: side)) { context, bounds in
            fill(context, bounds, UIColor(red: 0.78, green: 0.85, blue: 0.90, alpha: 1))
            fill(context, CGRect(x: 0, y: bounds.height * 0.7, width: bounds.width, height: bounds.height * 0.3),
                 UIColor(red: 0.62, green: 0.74, blue: 0.58, alpha: 1))
            context.setFillColor(UIColor(red: 0.99, green: 0.90, blue: 0.60, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: bounds.width * 0.62, y: bounds.height * 0.18, width: 54, height: 54))
        }
    }

    /// Faces 1…6 of a die in a 3 × 2 atlas (face n at column (n−1) % 3,
    /// row (n−1) / 3), ivory with black pips.
    static func diePips() -> Data {
        paint(size: CGSize(width: side * 1.5, height: side)) { context, bounds in
            fill(context, bounds, UIColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1))
            let cell = bounds.width / 3
            context.setFillColor(UIColor(white: 0.08, alpha: 1).cgColor)
            for face in 1...6 {
                let origin = CGPoint(x: CGFloat((face - 1) % 3) * cell, y: CGFloat((face - 1) / 3) * cell)
                for pip in pips(for: face) {
                    let radius = cell * 0.09
                    let centre = CGPoint(x: origin.x + pip.x * cell, y: origin.y + pip.y * cell)
                    context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
                }
            }
        }
    }

    /// A leaf, tip at the top, on a transparent ground (a MASK material).
    static func leaf() -> Data {
        paint(size: CGSize(width: 128, height: 192), opaque: false) { context, bounds in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: bounds.midX, y: 4))
            path.addCurve(to: CGPoint(x: bounds.midX, y: bounds.height - 4),
                          controlPoint1: CGPoint(x: bounds.width + 10, y: bounds.height * 0.35),
                          controlPoint2: CGPoint(x: bounds.width * 0.85, y: bounds.height * 0.95))
            path.addCurve(to: CGPoint(x: bounds.midX, y: 4),
                          controlPoint1: CGPoint(x: bounds.width * 0.15, y: bounds.height * 0.95),
                          controlPoint2: CGPoint(x: -10, y: bounds.height * 0.35))
            context.setFillColor(UIColor(red: 0.30, green: 0.62, blue: 0.30, alpha: 1).cgColor)
            context.addPath(path.cgPath)
            context.fillPath()
            context.setStrokeColor(UIColor(red: 0.52, green: 0.80, blue: 0.48, alpha: 1).cgColor)
            context.setLineWidth(5)
            context.move(to: CGPoint(x: bounds.midX, y: 12))
            context.addLine(to: CGPoint(x: bounds.midX, y: bounds.height - 12))
            context.strokePath()
        }
    }

    /// A five-petal flower on a transparent ground.
    static func flower() -> Data {
        paint(size: CGSize(width: 128, height: 128), opaque: false) { context, bounds in
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            context.setFillColor(UIColor(red: 0.96, green: 0.55, blue: 0.70, alpha: 1).cgColor)
            for petal in 0..<5 {
                let angle = CGFloat(petal) / 5 * 2 * .pi - .pi / 2
                let at = CGPoint(x: centre.x + cos(angle) * 34, y: centre.y + sin(angle) * 34)
                context.fillEllipse(in: CGRect(x: at.x - 26, y: at.y - 26, width: 52, height: 52))
            }
            context.setFillColor(UIColor(red: 0.99, green: 0.85, blue: 0.35, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: centre.x - 18, y: centre.y - 18, width: 36, height: 36))
        }
    }

    // MARK: - Helpers

    private static func pips(for face: Int) -> [CGPoint] {
        let low: CGFloat = 0.25, mid: CGFloat = 0.5, high: CGFloat = 0.75
        switch face {
        case 1: return [CGPoint(x: mid, y: mid)]
        case 2: return [CGPoint(x: low, y: low), CGPoint(x: high, y: high)]
        case 3: return [CGPoint(x: low, y: low), CGPoint(x: mid, y: mid), CGPoint(x: high, y: high)]
        case 4: return [CGPoint(x: low, y: low), CGPoint(x: high, y: low), CGPoint(x: low, y: high), CGPoint(x: high, y: high)]
        case 5:
            return [CGPoint(x: low, y: low), CGPoint(x: high, y: low), CGPoint(x: mid, y: mid),
                    CGPoint(x: low, y: high), CGPoint(x: high, y: high)]
        default:
            return [CGPoint(x: low, y: low), CGPoint(x: low, y: mid), CGPoint(x: low, y: high),
                    CGPoint(x: high, y: low), CGPoint(x: high, y: mid), CGPoint(x: high, y: high)]
        }
    }

    private static func paint(size: CGSize, opaque: Bool = true, _ body: (CGContext, CGRect) -> Void) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).pngData { renderer in
            body(renderer.cgContext, CGRect(origin: .zero, size: size))
        }
    }

    private static func fill(_ context: CGContext, _ rect: CGRect, _ colour: UIColor) {
        context.setFillColor(colour.cgColor)
        context.fill(rect)
    }

    private static func rounded(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let system = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = system.fontDescriptor.withDesign(.rounded) else { return system }
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func draw(_ text: String, in rect: CGRect, font: UIFont, colour: UIColor, lines: Int = 1) {
        guard !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: paragraph])
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}
