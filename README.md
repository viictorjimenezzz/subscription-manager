# Codex Quota

A minimal native macOS menu-bar app for monitoring the weekly Codex quota of up to four ChatGPT accounts.

Each account uses its own isolated `CODEX_HOME`. Codex Quota never reads, replaces, or logs out the account used by the official Codex app, CLI, or IDE extension.

## Features

- Up to four persistent ChatGPT account sessions
- Weekly Codex usage percentage and reset date
- Green, orange, and red quota bars
- One-click refresh for all accounts or an individual account
- Automatic refresh every 15 minutes
- Native translucent SwiftUI menu-bar window
- Optional launch at login
- No analytics and no external service operated by this project

## Requirements

- macOS 13 or newer (optimized for macOS Tahoe)
- Apple Silicon Mac
- Codex CLI installed at `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, or `~/.local/bin/codex`

Install the Codex CLI with Homebrew if needed:

```sh
brew install --cask codex
```

## Install

From this repository:

```sh
./scripts/install.sh
```

The script builds and ad-hoc signs the app, installs it in `~/Applications`, and launches it. Look for the small chart icon in the macOS menu bar.

## First-time setup

1. Click the Codex Quota icon in the menu bar.
2. Select **Connect an account**.
3. Finish the OpenAI sign-in in the browser window that opens.
4. Repeat for the remaining accounts.
5. Use the refresh button in the top-right whenever you want a fresh reading.

Codex refreshes active ChatGPT tokens automatically. A new browser login is only expected if OpenAI revokes a session or the account's security settings change.

## Privacy and isolation

Account profiles are stored in:

```text
~/Library/Application Support/CodexQuota/Profiles/
```

Each profile is a private directory with file permissions restricted to the current macOS user. The contained `auth.json` files are credentials and must never be shared or committed. Removing an account from the app logs it out and deletes its isolated profile.

The app communicates only with the locally installed Codex app-server and OpenAI's normal Codex authentication/usage services. It does not send data to any developer-owned backend.

## Development

```sh
./scripts/test.sh
./scripts/integration-test.sh
./scripts/build-app.sh
```

The parser test harness uses `swiftc` directly so it also runs on machines with Apple Command Line Tools but without the full Xcode application.

The packaged application is created at `dist/Codex Quota.app`.

## Implementation note

Codex Quota uses the structured local Codex app-server methods for account login, account identity, and rate limits. The app-server is currently marked experimental by Codex, so a future Codex release may require a compatibility update.
