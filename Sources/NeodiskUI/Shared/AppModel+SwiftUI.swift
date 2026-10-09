//
//  AppModel+SwiftUI.swift
//  Neodisk
//
//  SwiftUI colors over NeodiskAppModel's platform-neutral RGB vocabulary.
//  The shared model speaks SIMD3<Float> sRGB triples so every platform's
//  shell draws the same hues; this is the macOS shell's translation.
//

import SwiftUI
import NeodiskKit
import NeodiskAppModel

extension Color {
    /// The SwiftUI color for a palette RGB triple (sRGB components 0…1).
    init(rgb: SIMD3<Float>) {
        self.init(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
}

extension VizPalette {
    func ageColor(_ bucket: AgeBucket) -> Color {
        Color(rgb: ageRGB(bucket))
    }
}

extension FileKindStat {
    var color: Color {
        Color(rgb: rgb)
    }
}

extension FileKindCatalog {
    static var otherColor: Color {
        Color(rgb: otherRGB)
    }

    func color(for node: FileNodeRecord) -> Color {
        Color(rgb: rgb(for: node))
    }
}
