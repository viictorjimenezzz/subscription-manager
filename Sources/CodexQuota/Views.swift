import AppKit
import SwiftUI

struct QuotaPopoverView: View {
    @ObservedObject var store: AccountStore
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var showAccountActions: UUID?

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().opacity(0.55)
                content
                Divider().opacity(0.55)
                footer
            }
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(nil)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Quota")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("Weekly usage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        .padding(.vertical, 13)
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
            VStack(spacing: 0) {
                ForEach(store.accounts) { account in
                    AccountRow(
                        account: account,
                        state: store.states[account.id] ?? .idle,
                        onRefresh: { Task { await store.refresh(account.id) } },
                        onRemove: { Task { await store.remove(account.id) } }
                    )
                    if account.id != store.accounts.last?.id {
                        Divider().padding(.leading, 16).opacity(0.4)
                    }
                }
            }
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
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if state.isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else if let quota = account.quota {
                    Text("\(quota.clampedPercent)%")
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(color(for: quota.clampedPercent))
                }
                Menu {
                    Button("Refresh", action: onRefresh)
                    Divider()
                    Button("Remove account", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let quota = account.quota {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(0.16))
                        Capsule()
                            .fill(color(for: quota.clampedPercent).gradient)
                            .frame(width: geometry.size.width * CGFloat(quota.clampedPercent) / 100)
                    }
                }
                .frame(height: 6)
                .animation(.easeOut(duration: 0.35), value: quota.clampedPercent)

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
        .padding(.vertical, 13)
    }

    private var subtitle: String {
        let email = account.email ?? "Not connected"
        guard let plan = account.plan, !plan.isEmpty else { return email }
        return "\(email) · \(plan.replacingOccurrences(of: "_", with: " ").capitalized)"
    }

    private func color(for percent: Int) -> Color {
        switch percent {
        case ..<60: return .green
        case 60..<85: return .orange
        default: return .red
        }
    }

    private func resetText(for quota: QuotaSnapshot) -> String {
        guard let date = quota.resetsAt else { return "Reset date unavailable" }
        return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))"
    }
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
