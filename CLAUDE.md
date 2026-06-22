# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

**Seven Island** is a macOS notch enhancement app — it turns the MacBook notch into a dynamic hub: music controls, calendar, clipboard history, file shelf with AirDrop, HUD replacement (volume/brightness), and developer tool monitoring (Codex/Claude Code sessions). Written in SwiftUI for macOS 14+.

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
| `sevenIslandFeatureNotchHeight` | 360 (1.5×) | Clipboard, VS Code, Codex/Claude views (max open height) |
| `windowSize` | 640×500 | Window frame (covers max height + shadow) |

### ContentView structure (`ContentView.swift`)
```
NotchLayout()                         // VStack: header + body
  ├── BoringHeader()                  // Tab bar, "open notch" chrome
  └── (if open) content switch:
        .home         → NotchHomeView
        .shelf        → ShelfView
        .clipboard    → ClipboardHistoryView
        .vscodeProjects → VSCodeProjectsView
        .codexStatus  → CodexStatusView
        .claudeStatus → ClaudeStatusView
```

**Closed state** renders live activities directly in NotchLayout (music visualizer, Codex/Claude activity icons, battery notifications, face animation). Open/closed transitions are animated springs.

### Seven Island feature modules

Each feature under `components/SevenIsland/` follows the pattern: **Model → Service → View**:

| Feature | Models | Service | View |
|---|---|---|---|
| Codex status | `Models/CodexStatusSnapshot.swift` | `Services/CodexStatusService.swift` | `Views/CodexStatusView.swift` |
| Claude status | `Models/ClaudeStatusSnapshot.swift` | `Services/ClaudeStatusService.swift` | `Views/ClaudeStatusView.swift` |
| Clipboard | `Models/ClipboardHistoryItem.swift` | `Services/ClipboardHistoryStore.swift` | `Views/ClipboardHistoryView.swift` |
| VS Code | `Models/VSCodeProjectItem.swift` | `Services/VSCodeRecentProjectsService.swift` | `Views/VSCodeProjectsView.swift` |

**Service pattern:** Singleton `ObservableObject` with `@Published private(set) var snapshot` and a `refresh()` method that dispatches background work to `.global(qos: .utility)` then publishes results on `.main`. Views observe the service and poll via a 10-second `Timer.publish` `.onReceive`.

**Dynamic notch height:** For Claude and Codex views, the ContentView does NOT set a fixed notch height. Each view's `.task` modifier computes its own height based on session count (`count * 38 + chrome`) and calls `vm.setOpenNotchHeight()`. ContentView keeps the current height (`vm.notchSize.height`) when switching to these views. This avoids animation conflicts between ContentView's 0.35s transition and the subview's 0.24s height update.

### Data sources for external tools
- **Codex:** reads `~/.codex/sessions/*.json` + `~/.codex/projects/{encoded-cwd}/{sessionId}.jsonl`. CWD encoding: replace `/` with `-`
- **Claude Code:** reads `~/.claude/sessions/*.json` + `~/.claude/projects/{encoded-cwd}/{sessionId}.jsonl`. CWD encoding: same `-` replacement. Session `startedAt` is a millisecond Unix timestamp (Int). JSONL tool_use blocks are inside `message.content[]` (not top-level). Idle threshold: 30 seconds
- **VS Code:** reads `~/Library/Application Support/Code/storage.json` for recent projects

### Adding a new tab/feature
1. Add `case yourFeature` to `NotchViews` enum in `enums/generic.swift`
2. Create Model → Service → View files under `components/SevenIsland/`
3. Add tab entry in `TabSelectionView.swift` (`tabs` array + icon routing)
4. Add view routing in `ContentView.swift` NotchLayout switch
5. If it needs a live activity in closed notch: add computed properties and view builder in ContentView
6. Wire notch height: set initial height in `onChange(of: vm.notchState)` and `onChange(of: coordinator.currentView)`. For dynamic height views, keep `vm.notchSize.height` (no forced change) and let the view manage its own height via `.task`

### Key patterns
- **`Defaults`** (from `swiftui-defaults`) for all user preferences — keys defined in `models/Constants.swift` as `extension Defaults.Keys`
- **`@AppStorage`** used in BoringViewCoordinator for tab persistence, `firstLaunch`, `musicLiveActivityEnabled`
- **Custom Shapes** for app icons — SVG path data tokenized at init time into `CGMutablePath`, scaled in `path(in:)` via `CGAffineTransform`
- **Shelf** feature uses a separate suite of services under `components/Shelf/Services/` including `ShelfPersistenceService` (JSON file storage), `ThumbnailService`, `QuickLookService`, `QuickShareService`
- **HUD replacement** uses XPC helper (`BoringNotchXPCHelper`) for accessibility permissions and media key interception
