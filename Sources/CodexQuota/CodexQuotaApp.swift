import SwiftUI

@main
struct CodexQuotaApp: App {
    @StateObject private var store = AccountStore()

    var body: some Scene {
        MenuBarExtra {
            QuotaPopoverView(store: store)
        } label: {
            Label("Codex Quota", systemImage: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        let maximum = store.accounts.compactMap(\.quota?.clampedPercent).max() ?? 0
        switch maximum {
        case 85...: return "chart.bar.fill"
        case 60...: return "chart.bar"
        default: return "chart.bar.xaxis"
        }
    }
}
