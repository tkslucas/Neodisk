// SwiftUI colors over the shared model's sRGB SIMD3<Float> triples, so every shell draws the same hues.

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
