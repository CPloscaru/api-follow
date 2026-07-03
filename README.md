# APIFollow

A macOS menu bar app that tracks how much you're spending across your LLM/API
providers — at a glance, without opening five different dashboards.

## Features

- **Menu bar summary**: total spend this month, plus a per-provider row
  showing either remaining balance ("$X left") or month-to-date spend
  ("$X spent"), whichever the provider's API exposes.
- **Dashboard window**: per-day spend chart and history for any configured
  provider.
- **Floating overlay widget**: an always-on-top mini view for keeping an eye
  on spend while working.
- **Live polling**: providers with a prepaid/credit model (OpenRouter, fal.ai,
  Apify) poll every 30 seconds; others every 5 minutes.
- **Claude Code plan usage**: if Claude Code is installed and logged in,
  shows session (5h) and weekly rate-limit utilization.
- Keys are stored in the macOS Keychain, never on disk in plaintext.

### Supported providers

| Provider   | Spend history | Balance / envelope remaining |
|------------|:--------------:|:-----------------------------:|
| Anthropic  | ✅ | — (pay-as-you-go, no balance concept) |
| OpenAI     | ✅ | — (pay-as-you-go, no balance concept) |
| OpenRouter | ✅ | ✅ prepaid credits |
| fal.ai     | ✅ | ✅ prepaid credits |
| Apify      | ✅ | ✅ monthly plan cap remaining |

Each provider requires an **Admin/Management-scoped** API key, not a regular
one — the in-app key entry field for each provider links to where to create
it.

## Requirements

- macOS 13+
- Swift 6 toolchain (Xcode 16+, or the standalone Swift toolchain)

## Building and running

```sh
swift build
swift test
```

`swift run` launches a bare executable — macOS's Dock/menu-bar/activation
machinery is unreliable for GUI apps run that way. Use the packaging script
instead, which builds a real `.app` bundle and launches it:

```sh
./scripts/build-app.sh
```

If the app is already running, `open` on the bundle just re-activates the
existing process instead of picking up a new build — quit it first
(`pkill APIFollow` or Cmd-Q) before re-running the script to pick up code
changes.

## Architecture

Each provider is a `ProviderAdapter` (spend history) and, optionally, a
`BalanceFetcher` (remaining balance/credits) — see
`Sources/APIFollow/Adapters/ProviderAdapter.swift`. Adding a new provider
means implementing one or both of these against its API and registering it
in `APIFollowApp.init()` (`Sources/APIFollow/App.swift`); no other code
needs to change. `Poller` (`Sources/APIFollow/Polling/Poller.swift`) owns an
independent polling loop per provider, so polling intervals can differ
per-provider.

## License

MIT — see [LICENSE](LICENSE).
