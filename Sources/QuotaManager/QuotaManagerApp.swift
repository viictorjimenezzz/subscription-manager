import AppKit
import SwiftUI

struct QuotaManagerApp: App {
    @StateObject private var store = AccountStore()

    var body: some Scene {
        MenuBarExtra {
            QuotaPopoverView(store: store)
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .accessibilityLabel("Quota Manager")
        }
        .menuBarExtraStyle(.window)
    }
}

@main
enum Entry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if CommandLineTool.shouldHandle(arguments) {
            exit(CommandLineTool.run(arguments))
        }
        QuotaManagerApp.main()
    }
}
