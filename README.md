# Codex Menu Bar

Codex Menu Bar is a local Codex, Cursor, and Antigravity plugin plus a macOS menu bar companion app.

![Codex Menu Bar Screenshot](assets/screenshot.png)

The plugin exposes an MCP status bridge. The companion app watches `~/.codex-menu-bar/status.json` and shows:

- `Codex | / - \` while running
- `Codex` when idle
- `Codex ?` when waiting for input
- `Codex *` when there is a message
- `Codex !` when something needs attention

It also watches recent Codex local activity files under `~/.codex/`. If those files change in the last few seconds, the app automatically switches to the animated running state even when no MCP/CLI status update was sent.

## Cursor & Antigravity Support

The macOS menu bar app supports multi-agent and multi-editor status monitoring with dedicated LED status dots and usage panels:

* **Cursor Editor Support**:
  - **Activity Watcher**: Monitors user activity via `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb-wal` modifications, and checks background execution logs under `~/Library/Application Support/Cursor/logs/` for active Cursor Agent/Composer tasks.
  - **LED Indicator**: Displays a **Teal LED dot** next to the main status icon, representing active agent or composer execution.
  - **Usage Panel**: Displays a dedicated **Cursor Tab** in the status detail view showing your current billing period spend, token usage, and fast/slow GPT usage statistics. It retrieves these by reading your session token securely from Cursor's local storage and querying Cursor's dashboard APIs.
* **Antigravity (AGY) Support**:
  - **Activity Watcher**: Watches local activity files under `~/.gemini/antigravity/` to track agent operations.
  - **LED Indicator**: Displays a **Purple LED dot** showing current agent task status.
  - **Usage Panel**: Displays active/total conversation counts and agent statistics in the **AGY Tab**.
* **Status Dot Indicators**:
  - **Running/Thinking**: Solid Purple (AGY) / Teal (Cursor) dot.
  - **Awaiting Approval**: Orange blinking dot.
  - **Completed/Done**: Solid Green dot.
  - **Error/Failed**: Solid Red dot.
* **Dynamic UI Adaptability**: If Cursor or Antigravity monitoring is disabled in settings, their respective tabs and menu items (status lines and separators) are automatically hidden. If only one tab is active (e.g. only Codex), the tab selector bar is hidden entirely to maximize space and provide a cleaner interface.


## Privacy & Local-First Philosophy

This project is built with a strict **local-first and privacy-centric** design:

* **Zero Data Collection**: We do not collect, store, or transmit any of your personal data, code, activity logs, or configurations to any telemetry or third-party analytics services.
* **Completely Local Operation**: Status monitoring, activity log analysis, and state updates run entirely on your local machine.
* **Direct LLM Communication Only**: Any API requests made by the app (e.g., retrieving live GPT usage limits or token statistics) are sent **directly** from your local machine to the official model provider endpoints (ChatGPT/Cursor dashboard APIs). There are no intermediary proxy servers, and your credentials or session tokens never leave your computer.

## Installation via Homebrew

You can install the macOS companion app directly using Homebrew Cask:

```bash
# One-liner install
brew install --cask choihunchul/tap/codex-menu-bar

# Or tap first, then install
brew tap choihunchul/tap
brew install --cask codex-menu-bar
```

## Build The Menu Bar App

```bash
swift build -c release
.build/release/CodexMenuBar
```

The app runs as a menu bar accessory without a Dock icon.

Only one instance runs at a time. If `CodexMenuBar` is launched again while another copy is already running, the new copy asks the old process to quit and then takes over.

## One-Step Setup And Verification

From the project root:

```bash
node scripts/codex-menu-bar-setup.mjs
```

This builds the release app if needed, opens the menu bar app, creates the local status file if missing, and verifies the local snapshot command.

To inspect the current local status snapshot:

```bash
node scripts/codex-status-cli.mjs snapshot --json
```

## Update Status Manually

```bash
node scripts/codex-status-cli.mjs running "Working on the plugin"
node scripts/codex-status-cli.mjs waiting "Waiting for approval"
node scripts/codex-status-cli.mjs idle "Ready"
```

## Auto Watch Settings

Auto watch is enabled by default.

Open the menu bar item and choose `Settings...` to change:

- Auto watch Codex activity
- Auto watch Antigravity activity
- Auto watch Cursor activity
- Active window seconds
- Poll interval seconds
- Weekly limit
- 5-hour limit

Settings are saved to `~/.codex-menu-bar/settings.json` and apply immediately.
The weekly and 5-hour limit fields are shown below the status separator in the menu.
When available, the app automatically reads live Codex usage and colors the menu bar title: `C` reflects the 5-hour limit and `X` reflects the weekly limit.
Green means plenty remains, orange means getting low, and red means close to exhausted.
If live usage is unavailable, it falls back to the newest local `codex.rate_limits` event in `~/.codex/logs_2.sqlite`.

Environment variables can still set the defaults when no settings file exists:

```bash
CODEX_MENU_BAR_ACTIVE_WINDOW_SECONDS=10 .build/release/CodexMenuBar
CODEX_MENU_BAR_AUTO_WATCH=0 .build/release/CodexMenuBar
CODEX_MENU_BAR_AGY_WATCH=0 .build/release/CodexMenuBar
CODEX_MENU_BAR_CURSOR_WATCH=0 .build/release/CodexMenuBar
CODEX_MENU_BAR_POLL_INTERVAL_SECONDS=1.5 .build/release/CodexMenuBar
CODEX_MENU_BAR_WEEKLY_LIMIT="42% used, resets Mon" .build/release/CodexMenuBar
CODEX_MENU_BAR_FIVE_HOUR_LIMIT="12 left, resets 17:30" .build/release/CodexMenuBar
```

By default, the app checks these state files by modification time:

* **Codex**:
  - `~/.codex/state_5.sqlite-wal`
  - `~/.codex/state_5.sqlite`
  - `~/.codex/.codex-global-state.json`
* **Cursor**:
  - `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb-wal` (monitors general editor activity)
  - `~/Library/Application Support/Cursor/logs/` (recursively checks `anysphere.cursor-agent-exec` log files for active Cursor Agent/Composer execution)

The log database is intentionally not watched by default because it can be noisy while Codex keeps background connections alive.

## Automatic Updates

The macOS app features an automatic self-updater:
* **Background Check**: If enabled in settings (defaults to enabled), the app queries the GitHub Releases API (`https://api.github.com/repos/choihunchul/codex-menu-bar/releases/latest`) in the background every 12 hours.
* **Manual Check**: You can manually click "Check for Updates..." in the menu at any time.
* **Installation**: When a newer version is found, it prompts you to update, downloads the `.dmg` package, mounts it, overwrites the old app bundle, and automatically relaunches itself.
* **Configuration**: You can toggle this behavior via `Settings...` -> `Auto check for updates`.

## Plugin Files

- `.codex-plugin/plugin.json` registers the plugin.
- `.mcp.json` registers the `codex-menu-bar` MCP server.
- `scripts/codex-status-mcp.mjs` provides `codex_menu_bar_set_status` and `codex_menu_bar_get_status`.
- `Sources/CodexMenuBar/main.swift` contains the macOS menu bar app.

## Current Limitation

Codex does not currently expose a stable public lifecycle event stream to local plugins. This project combines an explicit status bridge with a lightweight local activity watcher.

## CI/CD & Auto-Deployment to Homebrew Tap

This repository has GitHub Actions workflows configured to automate building and publishing:

1. **Tag Push (`v*`) / Manual Release**:
   - Compiles the macOS companion app, builds the `.dmg` package, and uploads it to GitHub Releases.
2. **Cask Publishing**:
   - On successful completion of the release workflow, the Cask publisher automatically downloads the DMG, calculates the sha256, updates the Cask file in the personal tap repository (`choihunchul/homebrew-tap`), and pushes the changes.
