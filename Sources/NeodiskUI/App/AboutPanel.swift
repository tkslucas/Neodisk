//
//  AboutPanel.swift
//  Neodisk
//

import AppKit

/// Project links used by the Help menu and the About panel.
enum AppLinks {
    static let repository = URL(string: "https://github.com/tkslucas/Neodisk")!
    static let reportIssue = URL(string: "https://github.com/tkslucas/Neodisk/issues/new/choose")!
    static let radix = URL(string: "https://github.com/colinvkim/Radix")!
}

/// The standard About panel with short credits: the GitHub repo, where to
/// report issues, and the Radix attribution (full notice at the end of
/// LICENSE).
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: AppVersion.string,
            .credits: credits(),
        ])
    }

    private static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4

        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let credits = NSMutableAttributedString()

        var repoLine = body
        repoLine[.link] = AppLinks.repository
        credits.append(NSAttributedString(
            string: "github.com/tkslucas/Neodisk\n",
            attributes: repoLine
        ))

        credits.append(NSAttributedString(
            string: NSLocalizedString(
                "Report issues and feature requests on GitHub.", comment: ""
            ) + "\n",
            attributes: body
        ))

        let radixLine = NSMutableAttributedString(
            string: NSLocalizedString(
                "Scan engine and sunburst derive from Radix by Colin Kim.",
                comment: ""
            ),
            attributes: body
        )
        // "Radix" stays untranslated in every catalog, so linking the
        // substring is safe across locales.
        if let range = radixLine.string.range(of: "Radix") {
            radixLine.addAttribute(
                .link,
                value: AppLinks.radix,
                range: NSRange(range, in: radixLine.string)
            )
        }
        credits.append(radixLine)

        return credits
    }
}
