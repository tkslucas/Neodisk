import Foundation
import NeodiskKit

/// With `NEODISK_SCAN_PROFILE=1`, pings the main queue every 16 ms and records
/// how long each ping waited (`profile.app.mainLatency`), plus every wait over
/// 50 ms (`profile.app.mainStall`): how responsive the window stays while a
/// scan streams partial maps into it.
enum MainThreadMonitor {
    nonisolated(unsafe) private static var started = false

    static func startIfProfiling() {
        guard ScanProfile.isEnabled, !started else { return }
        started = true
        let thread = Thread {
            while true {
                let since = ScanProfile.now()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    ScanProfile.addNamed("app.mainLatency", since: since)
                    if ScanProfile.now() &- since > 50_000_000 {
                        ScanProfile.addNamed("app.mainStall", since: since)
                    }
                    answered.signal()
                }
                answered.wait()
                Thread.sleep(forTimeInterval: 0.016)
            }
        }
        thread.qualityOfService = .utility
        thread.name = "com.neodisk.main-thread-monitor"
        thread.start()
    }
}
