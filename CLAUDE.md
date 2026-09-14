# CLAUDE.md — CornerCal.app (native)

Native macOS port of the Hammerspoon CornerCal (`~/.hammerspoon/cornercal*`), built for public download.
Started 14 Sep 2026. His calls: public download, EventKit data, native app (not Hammerspoon).

## Build & run
- `./build.sh` → `build/CornerCal.app` (universal, ad-hoc signed). Plain swiftc, SDK **26.5** (27.0 breaks swiftc 6.3.3).
- `dist-tools/make-dmg.sh` → `dist/CornerCal-<ver>.dmg` + `.zip`. `site/index.html` = download page (NOT deployed).
- Test flags: `--demo` (fake events, no calendar permission), `--welcome`, `--settings`, `--test-panel`,
  `--test-remind`, `--snapshot <png> [delay]` (banner PNG + debug txt), `--allow-second`.
- Top-level code must stay in `Sources/main.swift`.

## Rules
- **XProtect:** a 13 Sep native CornerCal was auto-trashed as malware. Keep the app free of dropper-like behaviour:
  no spawning processes, no `xattr`, no launchd plists, no self-copying. Launch at login = `SMAppService.mainApp`.
  After any big change, launch once by hand and check `/usr/bin/log show --last 5m --predicate 'process == "syspolicyd"'`.
  First native launch (14 Sep 14:31) was NOT flagged.
- Physics constants and design choices are ported from the Lua version — his tuning. Don't retune without asking.
- Coordinates: physics works in top-left screen coords (like Hammerspoon); convert only via `topLeft`/`cocoaRect`.
- HTML pages need `[hidden]{display:none!important}`: any `display:` rule otherwise beats the `hidden` attribute.
