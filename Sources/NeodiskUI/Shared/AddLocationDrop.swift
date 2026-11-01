// Folders dropped from Finder onto the window or the sidebar become sidebar locations; while one hovers, the area
// shows the familiar drop highlight so the drop is expected, not a surprise on release.

import SwiftUI

extension View {
    func addLocationDropTarget(model: NeodiskViewModel, cornerRadius: CGFloat = 8) -> some View {
        modifier(AddLocationDropTarget(model: model, cornerRadius: cornerRadius))
    }
}

private struct AddLocationDropTarget: ViewModifier {
    let model: NeodiskViewModel
    let cornerRadius: CGFloat

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                model.addDroppedFolders(urls)
            } isTargeted: { targeted in
                // The app's own items dragged around aren't new locations: no invitation for them.
                isTargeted = targeted && !model.cleanup.isDragInProgress
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.accentColor.opacity(0.08))
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(3)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}
