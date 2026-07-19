//
//  StatsEmptyState.swift
//  Neodisk
//
//  The centered empty / idle / error state shared by the stats tabs: an SF
//  Symbol over an optional bold title and a secondary message, with an
//  optional action button. Callers pass `Text` so each controls its own
//  localization (literal keys vs. already-formatted strings).
//

import SwiftUI

struct StatsEmptyState<Action: View>: View {
    let symbol: String
    var symbolSize: CGFloat = 28
    var title: Text?
    let message: Text
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: symbolSize))
                .foregroundStyle(.secondary)
            if let title {
                title
                    .font(.system(size: 12, weight: .semibold))
                    .multilineTextAlignment(.center)
            }
            message
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }
}

extension StatsEmptyState where Action == EmptyView {
    init(symbol: String, symbolSize: CGFloat = 28, title: Text? = nil, message: Text) {
        self.init(symbol: symbol, symbolSize: symbolSize, title: title, message: message) {
            EmptyView()
        }
    }
}
