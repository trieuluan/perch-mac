//
//  AlbumArtPalette.swift
//  Perch
//
//  Picks vivid colors from the album art for the "Album art" color mode.
//  Averaging all pixels (as upstream does) turns most covers into gray or
//  brown, which makes visualizers look washed out on a black notch. Instead,
//  this finds the two most prominent saturated hues and brightens them. For
//  covers with almost no color, it falls back to a soft gradient tinted by
//  whatever little hue the cover has.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class AlbumArtPalette: ObservableObject {
    static let shared = AlbumArtPalette()

    /// Two colors, left to right. Defaults to a neutral fallback until the
    /// first cover has been analyzed.
    @Published private(set) var colors: [Color] = AlbumArtPalette.fallback(hue: nil)

    private var cancellable: AnyCancellable?

    private init() {
        cancellable = MusicManager.shared.$albumArt
            .removeDuplicates { $0 === $1 }
            .receive(on: DispatchQueue.global(qos: .utility))
            .map { AlbumArtPalette.extract(from: $0) }
            .receive(on: RunLoop.main)
            .sink { [weak self] colors in
                MainActor.assumeIsolated { self?.colors = colors }
            }
    }

    // MARK: - Extraction

    private nonisolated static func extract(from image: NSImage) -> [Color] {
        guard let pixels = samplePixels(image, side: 32) else { return fallback(hue: nil) }

        // Weight each pixel's hue by how colorful and bright it is.
        let binCount = 18
        var weights = [CGFloat](repeating: 0, count: binCount)
        var sums = [(h: CGFloat, s: CGFloat, b: CGFloat)](repeating: (0, 0, 0), count: binCount)
        var totalWeight: CGFloat = 0
        var grayHueX: CGFloat = 0
        var grayHueY: CGFloat = 0

        for (r, g, b) in pixels {
            let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            guard v > 0.15 else { continue }
            // Faint tint for the fallback, even from nearly gray pixels.
            grayHueX += cos(h * 2 * .pi) * s
            grayHueY += sin(h * 2 * .pi) * s

            let weight = s * s * (0.4 + v)
            guard weight > 0.02 else { continue }
            let bin = min(binCount - 1, Int(h * CGFloat(binCount)))
            weights[bin] += weight
            sums[bin].h += h * weight
            sums[bin].s += s * weight
            sums[bin].b += v * weight
            totalWeight += weight
        }

        // Too little color in the cover: use the fallback gradient.
        let colorfulShare = totalWeight / CGFloat(pixels.count)
        guard colorfulShare > 0.015 else {
            let hasTint = abs(grayHueX) + abs(grayHueY) > CGFloat(pixels.count) * 0.01
            let hue = hasTint ? (atan2(grayHueY, grayHueX) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1) : nil
            return fallback(hue: hue)
        }

        let ranked = weights.indices.sorted { weights[$0] > weights[$1] }
        func color(ofBin bin: Int) -> Color {
            let w = max(weights[bin], 0.0001)
            let hue = sums[bin].h / w
            // Brighten and saturate so it reads on black.
            let saturation = max(0.55, min(1, sums[bin].s / w * 1.15))
            let brightness = max(0.8, min(1, sums[bin].b / w * 1.2))
            return Color(hue: hue, saturation: saturation, brightness: brightness)
        }

        let first = ranked[0]
        // Second color: the strongest hue at least ~60° away, else a shifted first.
        let second = ranked.dropFirst().first { bin in
            let distance = abs(bin - first)
            return min(distance, binCount - distance) >= 3 && weights[bin] > weights[first] * 0.12
        }
        if let second {
            return [color(ofBin: first), color(ofBin: second)]
        }
        let w = max(weights[first], 0.0001)
        let hue = sums[first].h / w
        return [
            color(ofBin: first),
            Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 1),
        ]
    }

    /// Soft gradient for colorless covers; tinted toward the cover's faint hue
    /// when there is one, otherwise a moonlight blue-to-lavender.
    private nonisolated static func fallback(hue: CGFloat?) -> [Color] {
        let base = hue ?? 0.6
        return [
            Color(hue: base, saturation: 0.45, brightness: 1),
            Color(hue: (base + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.35, brightness: 1),
        ]
    }

    /// Downscales the image and returns its pixels as sRGB components.
    private nonisolated static func samplePixels(_ image: NSImage, side: Int) -> [(CGFloat, CGFloat, CGFloat)]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var data = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &data, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var pixels: [(CGFloat, CGFloat, CGFloat)] = []
        pixels.reserveCapacity(side * side)
        for i in stride(from: 0, to: data.count, by: 4) {
            pixels.append((CGFloat(data[i]) / 255, CGFloat(data[i + 1]) / 255, CGFloat(data[i + 2]) / 255))
        }
        return pixels
    }
}
