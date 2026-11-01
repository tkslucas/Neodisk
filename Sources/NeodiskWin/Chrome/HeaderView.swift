// The top of the content layer: the location's name and summary, or the scan's progress. The bar is
// determinate, never moves backward within a scan, and is full exactly when the scan is done; the drifting
// stripe sheen is the liveness signal (it stops when the work does).

import CNeodiskWin
import Foundation
import WinSDK

@MainActor
final class HeaderView: SurfaceView {
    struct Progress: Equatable {
        /// Identifies one scan session; a new one starts the bar from empty.
        var sessionKey: String
        var fraction: Double
        var caption: String
    }

    struct State: Equatable {
        var title = ""
        var caption = ""
        var progress: Progress?
    }

    var state = State() {
        didSet {
            guard state != oldValue else { return }
            if let progress = state.progress {
                if progress.sessionKey != oldValue.progress?.sessionKey { shownFraction = 0 }
                shownFraction = max(shownFraction, min(1, max(0, progress.fraction)))
                startSheen()
            } else {
                stopSheen()
            }
            invalidate()
            refreshAccessibility()
            if state.progress != nil, Int(shownFraction * 100) != announcedPercent {
                announcedPercent = Int(shownFraction * 100)
                announceValueChange(Self.progressID)
            }
        }
    }

    private var shownFraction = 0.0
    private var announcedPercent = -1
    private var sheenPhase = 0.0
    private var lastTick: UInt64 = 0
    private var timerID: UINT_PTR = 0

    static let height: Double = 56
    private static let titleID: Int32 = 1
    private static let captionID: Int32 = 2
    private static let progressID: Int32 = 3

    init(parent: HWND) {
        super.init(parent: parent, role: NDW_ROLE_HEADER, name: L("Location"))
    }

    private var titleFrame: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: 28) }
    private var barFrame: CGRect { CGRect(x: 0, y: 34, width: bounds.width, height: 4) }
    private var captionFrame: CGRect {
        state.progress == nil
            ? CGRect(x: 0, y: 30, width: bounds.width, height: 20)
            : CGRect(x: 0, y: 40, width: bounds.width, height: 16)
    }

    override func elements() -> [Element] {
        var result = [
            Element(id: Self.titleID, role: NDW_ROLE_TEXT, name: state.title, frame: titleFrame, interactive: false),
        ]
        if let progress = state.progress {
            result.append(Element(
                id: Self.progressID, role: NDW_ROLE_PROGRESS, name: L("Scan progress"), help: progress.caption,
                frame: barFrame, value: (shownFraction * 100).rounded(), interactive: false
            ))
            result.append(Element(id: Self.captionID, role: NDW_ROLE_TEXT, name: progress.caption, frame: captionFrame,
                                  interactive: false))
        } else if !state.caption.isEmpty {
            result.append(Element(id: Self.captionID, role: NDW_ROLE_TEXT, name: state.caption, frame: captionFrame,
                                  interactive: false))
        }
        return result
    }

    override func draw(_ g: Gfx) {
        let theme = self.theme
        g.fill(bounds, theme.layer)
        g.text(state.title, in: titleFrame, style: .subtitle, color: theme.textPrimary)
        if let progress = state.progress {
            let bar = barFrame
            g.fill(bar, theme.track, radius: 2)
            let filled = CGRect(x: bar.minX, y: bar.minY, width: bar.width * shownFraction, height: bar.height)
            if filled.width > 0 {
                g.fill(filled, theme.accentFill, radius: 2)
                g.stripes(filled, radius: 2, period: 10, phase: sheenPhase, RGBA(hex: 0xFFFFFF, alpha: 0.28))
            }
            g.text(progress.caption, in: captionFrame, style: .captionNumeric, color: theme.textSecondary)
        } else {
            g.text(state.caption, in: captionFrame, style: TextStyle(size: 14, tabular: true), color: theme.textSecondary)
        }
    }

    // MARK: - Sheen

    private func startSheen() {
        guard timerID == 0 else { return }
        lastTick = GetTickCount64()
        timerID = SetTimer(hwnd, 1, 16, nil)
    }

    private func stopSheen() {
        guard timerID != 0 else { return }
        KillTimer(hwnd, timerID)
        timerID = 0
    }

    override func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        if message == UINT(WM_TIMER) {
            let now = GetTickCount64()
            // 18 DIPs a second, the other apps' sheen speed.
            sheenPhase += Double(now - lastTick) / 1000 * 18
            lastTick = now
            let s = Double(scale)
            let bar = barFrame
            var dirty = RECT(
                left: Int32(bar.minX * s) - 1, top: Int32(bar.minY * s) - 1,
                right: Int32(bar.maxX * s) + 1, bottom: Int32(bar.maxY * s) + 1
            )
            InvalidateRect(hwnd, &dirty, false)
            return 0
        }
        return super.handle(message, wParam, lParam)
    }
}
