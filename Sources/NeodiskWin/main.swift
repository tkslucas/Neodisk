// Dev entry point until the app window lands: the canvas demo, its benchmark and headless renders.

import Foundation

let status = MainActor.assumeIsolated { CanvasDemo.run() }
exit(status)
