# AI Usage

[简体中文](README.zh-CN.md) · [Download for macOS](https://github.com/lukewang4862/AI-Usage/releases/latest)

A small native macOS floating widget for Codex, Grok Bot, and Muse remaining usage and automatic reset countdowns.

## Download and install

1. Download **AI-Usage-v0.3.7-macOS-arm64.zip** from [Releases](https://github.com/lukewang4862/AI-Usage/releases/latest). The source-code archives are for developers.
2. Unzip it and drag **AI Usage.app** into **Applications**.
3. Open the app. It appears as a floating widget, with no Dock icon. Right-click it for **Settings**, refresh, or quit.

Requires **Apple silicon (M1 or later)** and **macOS 14 or later**. This release does not support Intel Macs. No developer tools are required to run the downloaded app.

**Signing:** this build is ad-hoc signed, not Apple-notarized. macOS may block its first launch. If you trust this download, use the app-specific **Open Anyway** option in **System Settings → Privacy & Security**, if offered. Do not disable system-wide security protections. Organizations may block unnotarized apps entirely.

## Features

- Separate usage rows for Codex, Grok Bot, and Muse; choose which services to show in Settings.
- Gradient usage bars and reset countdowns such as `5D 23:52` (days, hours, minutes).
- Drag anywhere within the physical screen boundary, including the Dock area.
- Magnetic docking at the left or right edge, automatic collapse, and expansion on hover.
- Compact edge handle with each service's remaining percentage.
- Codex reset-credit display and confirmation before use, when supported by the account.
- Refresh every 60 seconds. Failed reads show an error rather than stale usage.

## Connect your accounts

- **Codex:** install and sign in to Codex.app. The widget uses a separate local Codex app-server process to read your account limits.
- **Grok:** install and sign in to Grok Bot. The widget reads the current macOS user's Grok login storage and corresponding Keychain item, decrypts the token in memory, and requests usage from the service.
- **Muse:** right-click the widget, open Settings, and use the Muse login option. Sign in inside the widget's login window. The session is saved in the app's persistent macOS WebKit store. You can close the login window afterward.

Every user supplies their own accounts. The repository and release contain no account tokens, cookies, Keychain data, or personal usage snapshots. Account state is stored outside the app bundle. The original bundle identifier is retained so existing installations keep their preferences and Muse session.

The integrations depend on internal service interfaces and may require updates when providers change them. Muse attempts to rediscover its read-only usage action from public scripts when its previous action becomes invalid. This is not an official app from any provider. Documentation is in English; some app menus and error messages are currently in Chinese.

## Build from source

Requires an Apple silicon Mac, macOS 14+, and Xcode Command Line Tools.

```sh
bash build.sh
open "build/AI Usage.app"
```

The script compiles Swift sources, generates the icon, and ad-hoc signs the app under `build/`. It does not install the app or alter your accounts.

## Checks

```sh
"build/AI Usage.app/Contents/MacOS/CodexUsage" --self-test
```

Checks cover screen bounds, magnetic docking thresholds, and usage parsing. The optional `--drag-self-test` exercises native drag handlers and requires a working macOS graphical session; it is not a headless CI test. Live account reads require running the app normally.

## Project layout

- `Sources/`: AppKit UI and provider adapters.
- `Resources/`: app metadata and icon generator.
- `build.sh`: local build and signing script.
- `README.zh-CN.md`: Chinese overview.
- `使用说明.md`: Chinese usage guide and version history.
