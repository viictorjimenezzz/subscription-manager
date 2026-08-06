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
        .frame(width: 348)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(nil)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Codex Weekly Quota")
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
                Text("Keep every Codex account in view.")
                    .font(.system(size: 13, weight: .medium))
                Button("Connect an account") {
                    Task { await store.addAccount() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            VStack(spacing: 2) {
                ForEach(store.accounts) { account in
                    AccountRow(
                        account: account,
                        state: store.states[account.id] ?? .idle,
                        onRefresh: { Task { await store.refresh(account.id) } },
                        onRemove: { Task { await store.remove(account.id) } }
                    )
                }
            }
            .padding(.vertical, 4)
        }

        if let login = store.activeLogin {
            Divider().opacity(0.5)
            LoginBanner(instructions: login.instructions) {
                Task { await store.cancelActiveLogin() }
            }
        }

        if let error = store.globalError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(12)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if store.canAddAccount {
                Button {
                    Task { await store.addAccount() }
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .disabled(store.activeLogin != nil)
            } else {
                Text("4 accounts connected")
                    .foregroundStyle(.secondary)
            }
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
                Button("Quit Codex Quota") { NSApplication.shared.terminate(nil) }
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

private struct AccountRow: View {
    let account: AccountRecord
    let state: AccountRuntimeState
    let onRefresh: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(account.email ?? "Connecting account…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(account.email == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                if state.isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else if let quota = account.quota {
                    Text("\(quota.remainingPercent)%")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(color(forRemaining: quota.remainingPercent))
                }
                Menu {
                    Button("Refresh", action: onRefresh)
                    Divider()
                    Button("Remove account", role: .destructive, action: onRemove)
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

            if let quota = account.quota {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(0.16))
                        Capsule()
                            .fill(color(forRemaining: quota.remainingPercent))
                            .frame(width: geometry.size.width * CGFloat(quota.remainingPercent) / 100)
                    }
                }
                .frame(height: 4)
                .animation(.easeOut(duration: 0.35), value: quota.remainingPercent)

                HStack {
                    Text(resetText(for: quota))
                    Spacer()
                    if let updated = account.lastUpdated {
                        Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
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
        .padding(.vertical, 10)
    }

    private func color(forRemaining percent: Int) -> Color {
        switch percent {
        case 50...: return Color(red: 0.32, green: 0.62, blue: 0.46)
        case 25..<50: return Color(red: 0.76, green: 0.58, blue: 0.31)
        default: return Color(red: 0.72, green: 0.34, blue: 0.35)
        }
    }

    private func resetText(for quota: QuotaSnapshot) -> String {
        guard let date = quota.resetsAt else { return "Reset date unavailable" }
        return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))"
    }
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
    let onCancel: () -> Void

    var body: some View {
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
        .padding(13)
    }
}
