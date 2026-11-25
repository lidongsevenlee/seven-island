# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project overview

**Seven Island** is a macOS notch enhancement app with music controls, calendar, clipboard history, VS Code projects, a memo pad, and volume/brightness HUD replacement. Written in SwiftUI for macOS 14+.

The app uses a borderless, floating panel window positioned at the top-center of the screen, mimicking the notch. It has two visual states: **closed** (compact, lives in the notch area) and **open** (expanded, shows a tabbed interface).

## Building

### Preferred: `script/build_and_run.sh`

The script always builds first, then acts based on the mode argument:

```bash
./script/build_and_run.sh              # default: build + launch app
./script/build_and_run.sh run          # build + launch app
./script/build_and_run.sh --verify     # build + launch + wait 5s + confirm process alive
./script/build_and_run.sh --debug      # build + launch under LLDB
./script/build_and_run.sh --logs       # build + launch + stream logs by process name
./script/build_and_run.sh --telemetry  # build + launch + stream logs by subsystem ID
```

The script builds with `CODE_SIGNING_ALLOWED=NO` (ad-hoc signing) and places derived data at `build/DerivedData`. The built app is at `build/DerivedData/Build/Products/Debug/Seven Island.app`.

**Sandbox requirement:** When running this script from Codex's Bash tool, you must use `dangerouslyDisableSandbox: true` — the default sandbox blocks SPM package resolution during the xcodebuild step.

### Alternative: raw xcodebuild

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

Same sandbox caveat applies. Use `open boringNotch.xcodeproj` to build from Xcode instead — that avoids sandbox restrictions entirely.

## Release flow ("发布")

1. Confirm the version. Use the version the user specifies or ask for it. Run the checks relevant to the release changes and commit those changes on `main`.
2. Run `script/release.sh <version>` from a clean checkout of the release commit. If the working copy has other edits, use a separate worktree and fast-forward `main` to the version commit. Push `main` and the new `v<version>` tag together.
3. Watch the GitHub Actions **Release** run for the exact tag. Confirm the build, DMG packaging, Release upload, and **Commit Updated Appcast** succeed. Verify that the public release has `Seven-Island-<version>.dmg` and that the live `SUFeedURL` in `boringNotch/Info.plist` lists this version first with the correct build number, DMG URL, and Sparkle signature. The workflow uses the repository's `SPARKLE_PRIVATE_KEY` secret.
4. Once the DMG is available, update `index.html` on `gh-pages` with the new version, download URL, and release highlights. Commit and push the branch, wait for GitHub Pages to finish deploying, and check that the live page displays the new version and links to the released DMG. [Seven Island landing page](https://lidongsevenlee.github.io/seven-island/)

## Architecture

### Window management
- `AppDelegate` (in `boringNotchApp.swift`) creates a `BoringNotchSkyLightWindow` — a borderless, floating panel in a custom `NotchSpace` (detached from normal window spaces)
- Supports both single-display and multi-display modes via `Defaults[.showOnAllDisplays]`
- The window is positioned using `NSScreen.frame` and `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` for accurate notch alignment

### State: BoringViewModel + BoringViewCoordinator
- **`BoringViewModel`** (`models/BoringViewModel.swift`) — per-window state: `notchState` (`.open`/`.closed`), `notchSize`, `setOpenNotchHeight(CGFloat)` (clamped to `openNotchSize.height ... sevenIslandFeatureNotchHeight`), `close()`, `open()`
- **`BoringViewCoordinator`** (`BoringViewCoordinator.swift`) — app-global singleton: `currentView: NotchViews`, `sneakPeek`, `expandingView`, display preferences. `currentView` persists via `@AppStorage("sevenIslandLastNotchView")`

### Sizing constants (`sizing/matters.swift`)
| Constant | Value | Use |
|---|---|---|
| `openNotchSize` | 640×240 | Default open notch dimensions |
| `sevenIslandFeatureNotchHeight` | 360 (1.5×) | Maximum supported open height |
| `windowSize` | 640×500 | Window frame (covers max height + shadow) |

### ContentView structure (`ContentView.swift`)

```
NotchLayout()
  ├── BoringHeader()
  └── (if open) content switch:
        .music          → MusicHomeView
        .clipboard      → ClipboardHistoryView
        .vscodeProjects → VSCodeProjectsView
        .memo           → MemoView
```

The closed state renders music, battery notifications, HUD indicators, and the face animation. Open/closed transitions use animated springs. Unknown persisted tab identifiers fall back to `.music`.

### Seven Island feature modules

Features under `components/SevenIsland/` follow **Model → Service → View**:

| Feature | Model | Service | View |
|---|---|---|---|
| Clipboard | `Models/ClipboardHistoryItem.swift` | `Services/ClipboardHistoryStore.swift` | `Views/ClipboardHistoryView.swift` |
| VS Code | `Models/VSCodeProjectItem.swift` | `Services/VSCodeRecentProjectsService.swift` | `Views/VSCodeProjectsView.swift` |
| Memo | `Models/MemoItem.swift` | `Services/MemoStore.swift` | `Views/MemoView.swift` |

`ClipboardHistoryStore` monitors `NSPasteboard` and persists history to the app's Application Support directory. Copying a history item updates its recency and saves the new order. `VSCodeRecentProjectsService` scans the configured project directory, includes pinned folders, and uses VS Code's recent-folder data for ordering.

Search text lives in the per-window `BoringViewModel` through `clipboardSearchText` and `vscodeSearchText`, so it survives tab changes and notch closure during the app session. `closeAutomatically()` respects `isTextInputFocused`, shared by search fields and the memo editor. `closeAfterHoverExit(position:)` checks the actual mouse position because text entry can hide the cursor and end SwiftUI hover tracking.

`MemoStore` persists ordered memos, the selected memo, and the next memo number in `Defaults.Keys.memoLibrary`. It migrates the legacy `memoText` into the first memo. `MemoView` uses horizontal tabs with titles from each memo’s first nonblank line, a new-memo button, and inline two-step deletion: the delete icon changes to a confirmation button before removal. The `.memo` tab retains `menuBarItems` as its persisted identifier.

### Music audio spectrum

`MusicBarsView` displays player audio through the shared `MusicAudioSpectrum` service. Its subscriptions follow visible, playing music views across windows. A serial worker owns Core Audio tap startup and teardown because system authorization can block device startup. Capture targets the current player's bundle and helper processes. `AudioSpectrumAnalyzer` converts PCM frequency energy into bottom-aligned bands. This feature requires macOS 14.2+ and `NSAudioCaptureUsageDescription`; audio buffers stay in memory during analysis.

### Adding a new tab/feature

1. Add a case to `NotchViews` in `enums/generic.swift`.
2. Create the feature's model, service, and view under `components/SevenIsland/`.
3. Add its tab and icon to `components/Tabs/TabSelectionView.swift`.
4. Add routing to the `ContentView.swift` content switch.
5. Keep open-height changes coordinated through `vm.setOpenNotchHeight()`; current tabs use `openNotchSize.height`.

### Key patterns

- User preferences use `Defaults`; keys are defined in `models/Constants.swift`.
- `BoringViewCoordinator` uses `@AppStorage` for the last tab, first launch, and music activity preferences.
- App icons use custom SwiftUI shapes backed by cached SVG paths.
- HUD replacement uses `BoringNotchXPCHelper` for accessibility authorization and media key interception.

### Verification

- Run `./script/run_clipboard_tests.sh` for clipboard ordering, deduplication, and persistence.
- After building the Debug app, run `./script/run_notch_interaction_tests.sh` for input focus and dismissal behavior.
- Run `./script/run_memo_tests.sh` for memo migration, independent editing, selection, deletion, and persistence.
- Run `./script/run_feature_tests.sh` against the Debug app for clipboard, VS Code, and lyrics checks.
- Run `./script/run_audio_spectrum_tests.sh` for frequency response, silence, sample rates, stereo phase, and interleaved/planar PCM decoding.
