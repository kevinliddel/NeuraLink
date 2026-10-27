//
//  SkyStarCatalogue.swift
//  NeuraLink
//
//  The real bright stars, so the constellations read: every star of the
//  Yale Bright Star Catalogue down to magnitude 3.55 (sky_bright_stars.txt,
//  scripts/make_sky_tables.py), about 300 of them. The sky draws them as
//  small sprites over its procedural field of faint ones, sized and
//  brightened by magnitude and tinted by colour index.
//
//  Created by Dedicatus on 27/10/2026.
//

import Foundation
import Metal
import simd

/// One star as the GPU reads it. Matches `SkyStar` in SkyShader.metal.
struct SkyStarData {
    /// xyz = J2000 equatorial unit vector, w = V magnitude.
    var directionAndMagnitude: SIMD4<Float>
    /// rgb = colour, w unused.
    var color: SIMD4<Float>
}

enum SkyStarCatalogue {

    /// The catalogue in a GPU buffer, and how many stars it holds.
    static func makeBuffer(device: MTLDevice) -> (buffer: MTLBuffer, count: Int)? {
        let stars = load()
        guard !stars.isEmpty,
            let buffer = stars.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        else {
            nlLog("[Sky] bright-star catalogue missing: only the faint field is drawn", level: .error)
            return nil
        }
        buffer.label = "SkyStars"
        return (buffer, stars.count)
    }

    static func load() -> [SkyStarData] {
        guard let url = Bundle.main.url(forResource: "sky_bright_stars", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        var stars: [SkyStarData] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: " ").compactMap { Float($0) }
            guard fields.count == 4 else { continue }
            let ra = fields[0] * .pi / 180, dec = fields[1] * .pi / 180
            let direction = SIMD3<Float>(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
            let color = tint(colorIndex: fields[3])
            stars.append(SkyStarData(
                directionAndMagnitude: SIMD4<Float>(direction, fields[2]),
                color: SIMD4<Float>(color, 0)))
        }
        return stars
    }

    /// B−V colour index to a display tint: blue-white for hot stars
    /// (Rigel, −0.03), white (Sirius, 0.00), yellow (the sun, 0.65), orange
    /// (Arcturus, 1.23), orange-red (Antares, 1.83). Kept pale: to the eye
    /// only the brightest stars show colour at all.
    static func tint(colorIndex: Float) -> SIMD3<Float> {
        let stops: [(Float, SIMD3<Float>)] = [
            (-0.30, [0.70, 0.80, 1.00]),
            (0.00, [0.86, 0.91, 1.00]),
            (0.30, [1.00, 1.00, 1.00]),
            (0.65, [1.00, 0.95, 0.84]),
            (1.20, [1.00, 0.84, 0.66]),
            (1.80, [1.00, 0.74, 0.54])
        ]
        guard colorIndex > stops[0].0 else { return stops[0].1 }
        for (lower, upper) in zip(stops, stops.dropFirst()) where colorIndex <= upper.0 {
            let t = (colorIndex - lower.0) / (upper.0 - lower.0)
            return lower.1 + (upper.1 - lower.1) * t
        }
        return stops[stops.count - 1].1
    }
}
