import CoreGraphics
import CoreText
import Foundation
import ImageIO

extension ShortlistFile {
    /// The thumbnail FM shows beside the shortlist: a little clipboard, as a 358x358 JPEG.
    static func picture(count: Int, isStaff: Bool) throws -> [UInt8] {
        let side = 0x166
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ShortlistError.pictureFailed }

        // The drawing below uses the original's top-left coordinates.
        func box(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> CGRect {
            CGRect(x: x, y: side - y - height, width: width, height: height)
        }
        func fill(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
            context.setFillColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
        }

        fill(40, 46, 56)
        context.fill(box(0, 0, side, side))
        fill(232, 236, 240)
        context.fill(box(79, 70, 200, 250))
        fill(46, 160, 90)
        context.fill(box(129, 52, 100, 36))
        fill(60, 64, 72)
        for row in 0..<6 {
            context.fillEllipse(in: box(100, 112 + row * 28, 10, 10))
            context.fill(box(120, 114 + row * 28, 138, 7))
        }

        // Segoe UI Semibold at 13pt on Windows; 13pt is this many pixels at 96 dpi.
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 13 * 96 / 72, nil)
        let caption = "FM Starship  ·  \(count) \(isStaff ? "staff" : "players")"
        let text = NSAttributedString(string: caption, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font as Any,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, nil, nil)
        context.textPosition = CGPoint(x: (CGFloat(side) - width) / 2, y: CGFloat(side - 0x146) - ascent)
        CTLineDraw(line, context)

        guard let image = context.makeImage(),
              let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        else { throw ShortlistError.pictureFailed }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ShortlistError.pictureFailed }
        return [UInt8](data as Data)
    }
}
