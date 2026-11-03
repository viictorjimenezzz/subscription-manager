# Subscription Manager

A minimal native macOS menu-bar app that keeps several **Codex (ChatGPT)** and **Claude Code** subscription accounts logged in at once, shows how much quota each has left, and lets you or your agents switch between them without logging in again.

Each account lives in its own folder under `~/.subscription-manager`. Subscription Manager never reads, replaces, or logs out the account used by your default `~/.codex` or `~/.claude`.

## Features

- Any number of Codex and Claude Code accounts, each permanently logged in
- Banked Codex resets shown per account, and applied from the account's **⋯** menu
- Weekly quota, 5-hour session quota and per-model weekly limits, with reset times
- Green, orange, and red quota bars
- Automatic refresh every 15 minutes, or on demand
- A shared credentials folder plus a `subscription-manager` command for agents
- Native translucent SwiftUI menu-bar window
- Optional launch at login
- No analytics and no external service operated by this project

## Requirements

- macOS 13 or newer (optimized for macOS Tahoe), Apple Silicon
- For Codex accounts: the Codex CLI (`brew install --cask codex`)
- For Claude Code accounts: Claude Code (`brew install --cask claude-code`) and a Claude Pro, Max, Team or Enterprise subscription

The CLIs are found in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, or your login shell's `PATH`.

## Install

```sh
./scripts/install.sh
```

The script builds and ad-hoc signs the app, installs it as `~/Applications/Subscription Manager.app`, links the command-line tool to `~/.local/bin/subscription-manager`, and launches the app. Look for the white Codex icon in the menu bar.

Upgrading from **Quota Manager** or **Codex Quota**: the installer quits and removes the old app and its `quota-manager` command. On first launch your accounts move into `~/.subscription-manager` and stay logged in:

- Quota Manager's `~/.quota-manager` folder moves as a whole. Each Claude Code login is moved to its new Keychain key and checked before the old one is removed; if any check fails, everything is put back.
- Codex Quota's profiles in `~/Library/Application Support/CodexQuota` move into `~/.subscription-manager/codex/`, named after their email addresses.

Re-enable "Launch at login" from the menu afterwards, because the app has a new identity.

## Adding accounts

Accounts are added by an agent, not from the app. Ask your agent to add one; it follows `~/.subscription-manager/ADD.md`, which boils down to:

```sh
subscription-manager add claude --email someone@example.com   # prints a sign-in URL
subscription-manager add-code '<code>'                         # only if Claude shows a code
```

Open the URL in a browser logged into that email (or a private window) and approve. The command signs in inside a new folder named after the email (for example `claude/someone-example`), refuses to save a login for any other email, and registers the account; the running app shows it within seconds. With `--from-default` it instead moves the login that plain `codex` or `claude` uses into Subscription Manager.

Both CLIs refresh their tokens automatically. A new browser login is only needed if a provider revokes the session; then click **Sign in** on the account row. It signs in again inside the same folder, so the account keeps its name and agents keep working.

## Banked resets (Codex)

Codex occasionally grants free rate-limit resets. Each Codex row shows how many are banked. To spend one, open the row's **⋯** menu and choose **Apply reset…**, then confirm. If no current limit is eligible, Codex reports it and no credit is used. Agents can do the same with `subscription-manager reset codex/<slug>` (shows the count) and `--yes` (applies one, only after the user agrees). Claude Code has no equivalent.

## Switching accounts from agents

Every account is a ready-to-use home folder:

```text
~/.subscription-manager/
  accounts.json          accounts, remaining quota, folder and env var for each
  README.md              these rules, for agents
  codex/<slug>/          use as CODEX_HOME
  claude/<slug>/         use as CLAUDE_CONFIG_DIR
```

Point an agent at an account with one environment variable:

```sh
CODEX_HOME="$HOME/.subscription-manager/codex/work" codex exec "…"
CLAUDE_CONFIG_DIR="$HOME/.subscription-manager/claude/personal" claude -p "…"
```

Or use the `subscription-manager` command:

```sh
subscription-manager list                       # accounts and remaining quota
subscription-manager list --json                # the same, for scripts
subscription-manager pick claude                # the Claude account with the most quota left
subscription-manager env claude/personal        # shell lines that select an account (fish or sh)
subscription-manager exec codex/work -- codex exec "fix the tests"
subscription-manager exec "$(subscription-manager pick codex --min 20)" -- codex exec "…"
eval "$(subscription-manager env claude/personal)"     # sh/zsh
subscription-manager env claude/personal | source      # fish
```

Accounts can be named as `<provider>/<slug>`, a unique slug, or an email address. Quota figures come from the app's last refresh (at most 15 minutes old); `pick` treats a window whose reset time has passed as full.

### Rules that keep logins working

- **Use the exact path.** Claude Code stores each folder's login in the macOS Keychain under a key derived from the literal `CLAUDE_CONFIG_DIR` string. Use the absolute path from `accounts.json` or `subscription-manager path`, with no trailing slash and no symlinked alias; any other spelling looks logged out. `~` and `$HOME` are fine in a shell because they expand to the same string.
- **Never copy credentials.** Both providers rotate refresh tokens on use, so a copied `auth.json` or Keychain entry goes stale and can sign the original out. Always point at the folder in place.
- **Clear overriding variables.** `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` take priority over the folder's login. `subscription-manager env` and `exec` clear them for you.
- **Remove accounts from the app**, not with `logout` inside a folder.
- Claude Code logins live in the Keychain, so `claude/<slug>` folders only work on this Mac. For machines without the Keychain (CI, containers), use `claude setup-token` instead.

### Shared settings

Your normal settings follow you into every account. The first time each account folder is prepared, Subscription Manager symlinks these items when they exist:

- from `~/.claude`: `settings.json`, `CLAUDE.md`, `agents`, `commands`, `hooks`, `output-styles`, `plugins`, `skills`, `keybindings.json`
- from `~/.codex`: `AGENTS.md`, `prompts`, `rules`, `skills`, `hooks.json`

Delete a link to give that account its own copy; it is not recreated. Credentials, history and per-account state (`.claude.json`, `auth.json`, sessions) are never shared. Codex `config.toml` is per account (Subscription Manager pins `cli_auth_credentials_store = "file"` there), so copy any MCP servers or model settings you want into it.

## Privacy

`~/.subscription-manager` and every account folder are readable only by your macOS user (`0700`). The folders contain credentials and must never be shared or committed. Removing an account logs it out, deletes its Keychain entry (Claude Code), and deletes its folder.

The app only runs the locally installed `codex` and `claude` CLIs, which talk to OpenAI's and Anthropic's normal authentication and usage services. Reading Claude usage runs the local `/usage` command, which makes no model request and costs nothing. Nothing is sent to a developer-owned backend.

## Development

```sh
./scripts/test.sh               # self-tests (parsers, vault, migration, CLI)
./scripts/integration-test.sh   # talks to the installed codex and claude CLIs
./scripts/build-app.sh          # creates dist/Subscription Manager.app
./scripts/verify-accounts.sh    # checks every stored account works for agents (read-only)
```

The test harnesses use `swiftc` directly, so they also run with only the Apple Command Line Tools installed. Set `SUBSCRIPTION_MANAGER_HOME` to run the app or CLI against a scratch credentials folder; a scratch folder never adopts Codex Quota data.

## Implementation notes

- Codex accounts use the structured local `codex app-server` methods for login, identity, and rate limits. The app-server is marked experimental, so a future Codex release may need a compatibility update.
- Claude Code accounts use `claude auth login`, `claude auth status --json`, and `claude -p /usage`. The `/usage` text is parsed strictly; if its format changes, the account shows an error instead of a wrong number, and `./scripts/integration-test.sh` checks the live format.
