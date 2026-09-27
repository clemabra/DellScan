import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScannedPage: Identifiable {
    let id = UUID()
    let image: CGImage
    let dpi: Int
    private(set) var rotation = 0          // Vierteldrehungen im Uhrzeigersinn
    private(set) var thumbnail: CGImage
    private let baseThumbnail: CGImage

    init?(data: Data, dpi: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        self.image = image
        self.dpi = dpi
        self.baseThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? image
        self.thumbnail = baseThumbnail
    }

    var rotatedImage: CGImage { ImageDecoding.rotate(image, quarterTurns: rotation) }

    mutating func rotate(by turns: Int) {
        rotation = ((rotation + turns) % 4 + 4) % 4
        thumbnail = ImageDecoding.rotate(baseThumbnail, quarterTurns: rotation)
    }
}

enum ImageDecoding {
    /// Dreht um Vielfache von 90° im Uhrzeigersinn.
    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage {
        let turns = (quarterTurns % 4 + 4) % 4
        guard turns != 0 else { return image }
        let w = image.width, h = image.height
        let (nw, nh) = turns % 2 == 0 ? (w, h) : (h, w)
        let gray = image.colorSpace?.model == .monochrome
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return image }
        ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? image
    }

    /// WSD "dib" liefert teils eine Bitmap ohne BITMAPFILEHEADER – den ergänzen wir.
    static func bmpAddingFileHeader(_ dib: Data) -> Data? {
        let d = Data(dib)
        guard d.count > 40, !(d[0] == 0x42 && d[1] == 0x4D) else { return nil }
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        let headerSize = u32(0), bitCount = u16(14), compression = u32(16)
        var colors = u32(32)
        if colors == 0 && bitCount <= 8 { colors = 1 << bitCount }
        var offset = 14 + headerSize + colors * 4
        if compression == 3 && headerSize == 40 { offset += 12 }
        var out = Data("BM".utf8)
        for v in [14 + d.count, 0, offset] {
            out.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
        }
        return out + d
    }
}

enum Exporter {
    /// PDF mit korrekter physischer Seitengröße (aus dpi).
    static func pdf(_ pages: [ScannedPage]) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil,
                                  [kCGPDFContextCreator: "Dell Scan"] as CFDictionary) else { return nil }
        for page in pages {
            let image = page.rotatedImage
            let dpi = CGFloat(max(page.dpi, 1))
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) / dpi * 72, height: CGFloat(image.height) / dpi * 72)
            ctx.beginPage(mediaBox: &box)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// Einzelbild als JPEG (bzw. PNG bei Schwarzweiß) mit dpi-Angabe.
    static func imageFile(_ page: ScannedPage) -> (data: Data, ext: String)? {
        let image = page.rotatedImage
        let png = page.image.bitsPerPixel == 1
        let type = png ? UTType.png : UTType.jpeg
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: page.dpi,
            kCGImagePropertyDPIHeight: page.dpi,
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data, png ? "png" : "jpg")
    }
}
