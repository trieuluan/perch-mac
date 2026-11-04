# Perch

**Perch** is a small hub that lives at the top of your Mac's screen, around the notch. It shows what's playing, your calendar, a file shelf and system HUDs, and it is meant to grow beyond music.

Perch is a fork of [Boring Notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam. Like the original, it is licensed under **GPL-3.0** (see [LICENSE](./LICENSE)).

## Planned

- [ ] Real audio visualizer driven by system audio, not a canned animation
- [ ] Mini waveform in the menu bar, toggleable in Settings
- [ ] Better web music support (YouTube, SoundCloud, Zing MP3, NhacCuaTui…), with a browser extension for sites that don't expose Media Session
- [ ] More widgets beyond music

## Building from source

Requirements: **macOS 15.6+** and **Xcode 26+**.

```bash
git clone https://github.com/trieuluan/perch-mac.git
cd perch-mac
open boringNotch.xcodeproj
```

Then press `Cmd + R` in Xcode.

Internal folder, target and scheme names still say `boringNotch`. They were kept on purpose so upstream changes keep merging cleanly.

## Staying in sync with upstream

```bash
git remote add upstream https://github.com/TheBoredTeam/boring.notch.git  # once
git fetch upstream
git merge upstream/main
```

## Credits

- **[Boring Notch](https://github.com/TheBoredTeam/boring.notch)** by TheBoredTeam and contributors, which Perch is built on.
- **[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)**, for Now Playing access on macOS 15.4+.
- **[NotchDrop](https://github.com/Lakr233/NotchDrop)**, which inspired the original Shelf feature.

For third-party licenses, see [THIRD_PARTY_LICENSES](./THIRD_PARTY_LICENSES).
