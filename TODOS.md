# TODOS

## API Follow

### Burn-rate/velocity view + budget caps + color-shifting menu bar icon

**What:** Show $/hour spend velocity with forward projection ("hits your $200 cap by Thursday"), let the menu bar icon shift color (green→amber→red) as a pre-emptive alert, add per-provider/per-project budget caps.

**Why:** Surfaced by the /office-hours cross-model second opinion as the "coolest version not yet considered" — turns the app from a totals dashboard into a proactive early-warning system, which is closer to the original motivation (avoid billing surprises) than a static number.

**Context:** Requires a budget-cap field on the adapter/data model that v1 deliberately doesn't build yet (v1 schema should leave room for it — see design doc Open Questions). Depends on v1's polling/storage loop being solid first, since velocity calculations need reliable historical data.

**Effort:** M
**Priority:** P2
**Depends on:** v1 core loop (poller + SQLite + adapters) shipped and stable.

### Cross-device sync (iCloud or similar)

**What:** Decide whether spend history syncs across multiple Macs, and if so, how (iCloud, custom sync, or explicitly none).

**Why:** Left as an open question in the design doc — SQLite is local-only by default, and it's unclear whether that's acceptable long-term if the user runs this on more than one Mac.

**Context:** No decision made yet. If sync is wanted, this affects the SQLite schema and possibly a switch to CloudKit-backed persistence — better decided before too much data has accumulated locally, since migrating a populated local store to a synced store later is more work than designing for it from the start.

**Effort:** L
**Priority:** P3
**Depends on:** None — but cheaper to decide before v1 accumulates significant local history.

### Contribute a "spend-based" provider type upstream to OpenUsage

**What:** Instead of maintaining this as a fully separate project long-term, evaluate contributing a dollar-spend provider type to robinebers/openusage (or its community fork), since its plugin architecture is nearly identical to what this project independently designed.

**Why:** Considered and explicitly rejected for v1 (see design doc "Eng Review Decisions" D2) because OpenUsage's domain (quota/session limits) doesn't match this project's domain (dollar spend) closely enough to justify forking now. Worth revisiting once this project's adapter model has proven itself — contributing upstream avoids maintaining a permanently parallel project if the two problem domains turn out to be more mergeable than they look today.

**Context:** Would require reading OpenUsage's `docs/plugins/api.md` and `plugin.json`/`plugin.js` plugin format in detail (not yet done — this review only sampled the architecture docs, not the plugin API spec) to judge real compatibility.

**Effort:** M (investigation) / L (actual contribution)
**Priority:** P4
**Depends on:** This project's own adapter interface (design doc Next Steps #4) existing and proven across 2+ providers first.

### App Store distribution + sandboxing

**What:** Decide whether this ships via GitHub Releases/Homebrew only (current default assumption) or also through the Mac App Store, which would require sandboxing entitlements affecting Keychain access and network calls.

**Why:** Design doc's Distribution Plan is explicitly deferred ("premature for a weekend-one build"). This TODO exists so the decision isn't silently lost once v1 ships and distribution actually becomes relevant.

**Context:** Sandboxing decision is cheaper to make before the app has real users/installs than to retrofit after.

**Effort:** S (decision) / M (implementation if sandboxed)
**Priority:** P3
**Depends on:** v1 shipped and working locally first.

### Historical backfill when adding a new provider

**What:** Decide whether adding a new provider adapter pulls historical spend (where the provider's Admin API allows a lookback window) or starts tracking from zero going forward only.

**Why:** Left as an explicit open question in the design doc — depends on what each provider's Admin API actually allows querying historically, which wasn't verified during this review.

**Context:** Worth resolving once the adapter interface (design doc Next Steps #4) is being designed, since backfill support (or its absence) affects the adapter's method signature from the start.

**Effort:** S (decision) / M (implementation if backfill is wanted)
**Priority:** P3
**Depends on:** Adapter interface design (design doc Next Steps #4).
