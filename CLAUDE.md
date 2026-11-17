# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

**Seven Island** is a macOS notch enhancement app with music controls, calendar, clipboard history, VS Code projects, menu bar controls, and volume/brightness HUD replacement. Written in SwiftUI for macOS 14+.

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

**Sandbox requirement:** When running this script from Claude Code's Bash tool, you must use `dangerouslyDisableSandbox: true` — the default sandbox blocks SPM package resolution during the xcodebuild step.

### Alternative: raw xcodebuild

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

Same sandbox caveat applies. Use `open boringNotch.xcodeproj` to build from Xcode instead — that avoids sandbox restrictions entirely.

## Release flow ("提交发布")

When the user says "提交发布", do the following:

1. **Ask for the new version number** (e.g. "1.1.0"). If they don't specify, ask.
2. **Run `script/release.sh <version>`** inside the sandbox — this updates MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.pbxproj, commits, and tags.
3. **Tell the user to run the push command** printed by the script (sandbox blocks git push):
   ```
   git push origin main --tags
   ```

The tag push triggers the GitHub Actions release workflow (`.github/workflows/release.yml`) which builds, DMG-packages, Sparkle-signs, and creates the GitHub Release.

**One-time setup required:** `SPARKLE_PRIVATE_KEY` secret must exist in GitHub repository settings. If missing, the release workflow will fail at the signing step.

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
        .menuBarItems   → MenuBarItemsView
```

The closed state renders music, battery notifications, HUD indicators, and the face animation. Open/closed transitions use animated springs. Unknown persisted tab identifiers fall back to `.music`.

### Seven Island feature modules

Features under `components/SevenIsland/` follow **Model → Service → View**:

| Feature | Model | Service | View |
|---|---|---|---|
| Clipboard | `Models/ClipboardHistoryItem.swift` | `Services/ClipboardHistoryStore.swift` | `Views/ClipboardHistoryView.swift` |
| VS Code | `Models/VSCodeProjectItem.swift` | `Services/VSCodeRecentProjectsService.swift` | `Views/VSCodeProjectsView.swift` |
| Menu bar | `Models/MenuBarProxyItem.swift` | `Services/MenuBarItemMonitor.swift` | `Views/MenuBarItemsView.swift` |

`ClipboardHistoryStore` monitors `NSPasteboard` and persists history to the app's Application Support directory. Copying a history item updates its recency and saves the new order. `VSCodeRecentProjectsService` scans the configured project directory, includes pinned folders, and uses VS Code's recent-folder data for ordering.

Search text lives in the per-window `BoringViewModel` through `clipboardSearchText` and `vscodeSearchText`, so it survives tab changes and notch closure during the app session. `closeAutomatically()` respects search focus. `closeAfterHoverExit(position:)` checks the actual mouse position because text entry can hide the cursor and end SwiftUI hover tracking.

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
- After building the Debug app, run `./script/run_notch_interaction_tests.sh` for search focus and dismissal behavior.
- Run `./script/run_feature_tests.sh` against the Debug app for clipboard, VS Code, and lyrics checks.
