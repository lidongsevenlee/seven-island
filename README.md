<h1 align="center">
  <br>
  <a href="https://github.com/lidongsevenlee/seven-island"><img src="https://framerusercontent.com/images/RFK4vs0kn8pRMuOO58JeyoemXA.png?scale-down-to=256" alt="Seven Island" width="150"></a>
  <br>
  Seven Island
  <br>
</h1>

<p align="center">
  <img src="https://github.com/lidongsevenlee/seven-island/actions/workflows/cicd.yml/badge.svg" alt="Seven Island Build & Test" style="margin-right: 10px;" />
  <a href="https://discord.gg/c8JXA7qrPm">
    <img src="https://dcbadge.limes.pink/api/server/https://discord.gg/c8JXA7qrPm?style=flat" alt="Discord Badge" />
  </a>
</p>

Say hello to **Seven Island**, the coolest way to make your MacBook's notch the star of the show! Your notch transforms into a dynamic music control center, complete with a vibrant visualizer and all the essential music controls you need. But that's just the start! Seven Island also offers calendar integration, a handy file shelf with AirDrop support, a complete macOS HUD replacement and more!

<p align="center">
  <img src="https://github.com/user-attachments/assets/2d5f69c1-6e7b-4bc2-a6f1-bb9e27cf88a8" alt="Demo GIF" />
</p>

---

## Installation

**System Requirements:**
- macOS **14 Sonoma** or later
- Apple Silicon or Intel Mac

---

### Build from Source

#### Prerequisites

- **macOS 14 or later**: If you're not on the latest macOS, we might need to send a search party.
- **Xcode 16 or later**: This is where the magic happens, so make sure it's up-to-date.

#### Steps

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/lidongsevenlee/seven-island.git
   cd seven-island
   ```

2. **Open the Project in Xcode**:
   ```bash
   open boringNotch.xcodeproj
   ```

3. **Build and Run**:
   - Click the "Run" button or press `Cmd + R`. Watch the magic unfold!

---

### Build Script

```bash
./script/build_and_run.sh              # build + launch app
./script/build_and_run.sh --verify     # build + launch + confirm process alive
./script/build_and_run.sh --debug      # build + launch under LLDB
./script/build_and_run.sh --logs       # build + launch + stream logs
```

---

## Usage

- Launch the app, and voilà — your notch is now the coolest part of your screen.
- Hover over the notch to see it expand and reveal all its secrets.
- Use the controls to manage your music like a rockstar.
- Click the icon in your menu bar to customize to your heart's content.

## Features

- [x] Playback live activity
- [x] Calendar integration
- [x] Reminders integration
- [x] Camera mirror
- [x] Charging indicator and percentage
- [x] Shelf functionality with AirDrop
- [x] Notch sizing customization
- [x] System HUD replacements (volume, brightness, backlight)
- [x] Clipboard history manager
- [x] VS Code recent projects
- [x] Codex & Claude Code session monitor
- [x] Apple Music lyrics display
- [ ] Bluetooth Live Activity
- [ ] Weather integration
- [ ] Customizable Layout options
- [ ] Lock Screen Widgets
- [ ] Extension system
- [ ] Notifications (under consideration)

## 🤝 Contributing

Contributions are welcome! Feel free to open issues and pull requests.

## Join our Discord Server

<a href="https://discord.gg/GvYcYpAKTu" target="_blank"><img src="https://iili.io/28m3GHv.png" alt="Join our Discord!" style="height: 60px !important;width: 217px !important;" ></a>

## 🎉 Acknowledgments

We would like to express our gratitude to the authors and maintainers of the open-source projects that made this possible.

### Notable Projects
- **[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)** – An open-source project that allowed us to use the Now Playing source in macOS 15.4+
- **[NotchDrop](https://github.com/Lakr233/NotchDrop)** – An open-source project that has been instrumental in developing the first version of the "Shelf" feature.
- **[Boring Notch](https://github.com/TheBoredTeam/boring.notch)** – The original project that Seven Island is based on.

For a full list of licenses and attributions, please see the [Third-Party Licenses](./THIRD_PARTY_LICENSES.md) file.

- **SwiftUI**: For making us look like coding wizards.
- **You**: For being awesome and checking out **Seven Island**!
