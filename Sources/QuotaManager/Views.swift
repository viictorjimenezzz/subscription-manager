import AppKit
import SwiftUI

struct QuotaPopoverView: View {
    @ObservedObject var store: AccountStore
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        ZStack {
            TahoeTranslucentBackground().ignoresSafeArea()
            Color.primary.opacity(0.018).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().opacity(0.32)
                content
                Divider().opacity(0.32)
                footer
            }
        }
        .frame(width: 364)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(nil)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Quota Manager")
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
            Spacer()
            Button {
                Task { await store.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(store.isRefreshingAll ? .degrees(360) : .zero)
                    .animation(store.isRefreshingAll ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: store.isRefreshingAll)
            }
            .buttonStyle(.plain)
            .help("Refresh all accounts")
            .disabled(store.accounts.isEmpty || store.isRefreshingAll)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if store.accounts.isEmpty {
            VStack(spacing: 13) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Keep every Codex and Claude account in view.")
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 8) {
                    ForEach(Provider.allCases) { provider in
                        Button("Connect \(provider.displayName)") {
                            Task { await store.addAccount(provider) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Provider.allCases) { provider in
                    let accounts = store.accounts(for: provider)
                    if !accounts.isEmpty {
                        ProviderHeader(provider: provider)
                        ForEach(accounts) { account in
                            AccountRow(
                                store: store,
                                account: account,
                                state: store.states[account.id] ?? .idle
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }

        if let login = store.activeLogin {
            Divider().opacity(0.5)
            LoginBanner(
                instructions: login.instructions,
                onSubmitCode: { code in Task { await store.submitLoginCode(code) } },
                onCancel: { Task { await store.cancelActiveLogin() } }
            )
        }

        if let error = store.globalError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(Provider.allCases) { provider in
                    Button(provider.displayName) {
                        Task { await store.addAccount(provider) }
                    }
                    .disabled(!store.canAddAccount(provider))
                }
            } label: {
                Label("Add account", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(store.activeLogin != nil)

            Spacer()
            Menu {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        do {
                            try LaunchAtLogin.setEnabled(value)
                            launchAtLogin = value
                        } catch {
                            store.globalError = error.localizedDescription
                        }
                    }
                ))
                Divider()
                Button("Open credentials folder") { NSWorkspace.shared.open(store.vault.root) }
                Button("Copy credentials folder path") { copyToPasteboard(store.vault.root.path) }
                Divider()
                Button("Quit Quota Manager") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private struct ProviderHeader: View {
    let provider: Provider

    var body: some View {
        HStack(spacing: 6) {
            ProviderLogo(provider: provider)
                .frame(width: 12, height: 12)
            Text(provider.displayName.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 1)
    }
}

private struct ProviderLogo: View {
    let provider: Provider

    var body: some View {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Assets/\(provider.logoAsset)"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: provider == .codex ? "terminal" : "asterisk").resizable().scaledToFit()
        }
    }
}

private struct AccountRow: View {
    @ObservedObject var store: AccountStore
    let account: AccountRecord
    let state: AccountRuntimeState

    @State private var editingSlug: String?
    @State private var renameError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.email ?? (state == .awaitingLogin ? "Waiting for sign-in…" : "Connecting account…"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(account.email == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if state.isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else if let weekly = account.quota?.weekly {
                    Text("\(weekly.remainingPercent)%")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(color(forRemaining: weekly.remainingPercent))
                }
                rowMenu
            }

            if editingSlug != nil {
                renameEditor
            }

            if let quota = account.quota, let weekly = quota.weekly {
                QuotaBar(remaining: weekly.remainingPercent, color: color(forRemaining: weekly.remainingPercent))

                HStack(spacing: 10) {
                    Text(resetText(for: weekly))
                    Spacer()
                    ForEach(secondaryWindows(quota)) { window in
                        Text("\(window.label) \(window.remainingPercent)%")
                            .foregroundStyle(window.remainingPercent < 25 ? AnyShapeStyle(color(forRemaining: window.remainingPercent)) : AnyShapeStyle(.tertiary))
                            .help(resetText(for: window))
                    }
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)

                if case .failed(let message) = state {
                    Text(message).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            } else if case .failed(let message) = state {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(state == .awaitingLogin ? "Finish signing in in your browser" : "Waiting for quota data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .help(account.lastUpdated.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "")
    }

    private var subtitle: String {
        [account.reference, account.plan].compactMap { $0 }.joined(separator: " · ")
    }

    private var rowMenu: some View {
        Menu {
            Button("Refresh") { Task { await store.refresh(account.id) } }
            Divider()
            Button("Copy environment for agents") {
                copyToPasteboard(EnvironmentSnippet.lines(provider: account.provider, home: store.homePath(for: account), shell: .current).joined(separator: "\n"))
            }
            Button("Copy folder path") { copyToPasteboard(store.homePath(for: account)) }
            Button("Show folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.homePath(for: account))])
            }
            Button("Rename folder…") {
                renameError = nil
                editingSlug = account.slug
            }
            Divider()
            if case .failed = state {
                Button("Reconnect") { Task { await store.retryLogin(account.id) } }
            }
            Button("Remove account", role: .destructive) { Task { await store.remove(account.id) } }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 16)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var renameEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(account.provider.rawValue)/")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("folder name", text: Binding(
                    get: { editingSlug ?? "" },
                    set: { editingSlug = $0.lowercased() }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit(commitRename)
                Button("Save", action: commitRename).controlSize(.small)
                Button("Cancel") { editingSlug = nil }.controlSize(.small).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if let renameError {
                Text(renameError).font(.caption2).foregroundStyle(.red)
            }
        }
        .font(.caption)
    }

    private func commitRename() {
        guard let slug = editingSlug.map(Vault.sanitize) else { return }
        Task {
            do {
                try await store.rename(account.id, to: slug)
                editingSlug = nil
            } catch {
                renameError = error.localizedDescription
            }
        }
    }

    private func secondaryWindows(_ quota: QuotaSnapshot) -> [QuotaWindow] {
        quota.windows.filter { $0 != quota.weekly }
    }

    private func resetText(for window: QuotaWindow) -> String {
        guard let date = window.resetsAt else { return "Reset date unavailable" }
        return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))"
    }
}

private struct QuotaBar: View {
    let remaining: Int
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.16))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(remaining) / 100)
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.35), value: remaining)
    }
}

private func color(forRemaining percent: Int) -> Color {
    switch percent {
    case 50...: return Color(red: 0.32, green: 0.62, blue: 0.46)
    case 25..<50: return Color(red: 0.76, green: 0.58, blue: 0.31)
    default: return Color(red: 0.72, green: 0.34, blue: 0.35)
    }
}

@MainActor
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct TahoeTranslucentBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct LoginBanner: View {
    let instructions: LoginInstructions
    let onSubmitCode: (String) -> Void
    let onCancel: () -> Void

    @State private var code = ""
    @State private var submitted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish connecting in your browser")
                        .font(.caption.weight(.medium))
                    Button("Open sign-in again") { NSWorkspace.shared.open(instructions.authURL) }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if instructions.acceptsCode {
                HStack(spacing: 6) {
                    TextField("Paste the code shown after sign-in", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit(submit)
                    Button(submitted ? "Sent" : "Submit", action: submit)
                        .controlSize(.small)
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || submitted)
                }
            }
        }
        .padding(13)
    }

    private func submit() {
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        submitted = true
        onSubmitCode(code)
    }
}
