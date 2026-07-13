//
//  AboutView.swift
//  Neodisk
//

import AppKit
import SwiftUI

/// Project links used by the Help menu and the About window.
enum AppLinks {
    static let repository = URL(string: "https://github.com/tkslucas/Neodisk")!
    static let reportIssue = URL(string: "https://github.com/tkslucas/Neodisk/issues/new/choose")!
    static let sponsor = URL(string: "https://github.com/sponsors/tkslucas")!
    /// The license page also carries the Radix attribution notice.
    static let license = URL(string: "https://github.com/tkslucas/Neodisk/blob/main/LICENSE")!
    static let privacy = URL(string: "https://neodisk.app/privacy")!
}

/// Custom About window: icon, name, version, Support/GitHub buttons, and a
/// license link. Replaces the standard about panel.
struct AboutView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 108, height: 108)

            Text(verbatim: "Neodisk")
                .font(.title)
                .bold()
                .padding(.top, 4)

            Text("Version \(AppVersion.string)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 6)

            HStack(spacing: 8) {
                Button("Support") {
                    openURL(AppLinks.sponsor)
                }
                Button {
                    openURL(AppLinks.repository)
                } label: {
                    Text(verbatim: "GitHub")
                }
            }
            .padding(.top, 24)

            HStack(spacing: 6) {
                Link("License", destination: AppLinks.license)
                Text(verbatim: "·")
                Link("Privacy", destination: AppLinks.privacy)
            }
            .font(.caption)
            .tint(.secondary)
            .padding(.top, 20)
        }
        .padding(.top, 24)
        .padding(.bottom, 20)
        .padding(.horizontal, 40)
        .frame(minWidth: 260)
        .background(
            VisualEffectBackground(material: .underWindowBackground)
                .ignoresSafeArea()
        )
    }
}

/// Background like the system "About This Mac" window.
private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
