# Perch

**Perch** is a small hub that lives at the top of your Mac's screen, around the notch. It shows what's playing, your calendar, a file shelf and system HUDs, and it is meant to grow beyond music.

Perch is a fork of [Boring Notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam. Like the original, it is licensed under **GPL-3.0** (see [LICENSE](./LICENSE)).

## Install

Requires **macOS 14 Sonoma or later** (visualizers need 14.2+).

**With Homebrew** (recommended):

```bash
brew install --cask trieuluan/perch/perch
```

**Or download** `Perch.dmg` from the [latest release](https://github.com/trieuluan/perch-mac/releases/latest) and drag Perch into Applications.

Perch isn't notarized by Apple yet, so the first time you open a downloaded copy, macOS blocks it. To allow it, go to **System Settings › Privacy & Security**, find the message about Perch, and click **Open Anyway**. Or run:

```bash
xattr -dr com.apple.quarantine /Applications/Perch.app
```

The Homebrew cask does this for you. After that, Perch updates itself through Sparkle.

## What Perch adds

### Visualizers that follow the real audio

Perch listens to what your Mac is playing (a Core Audio process tap, macOS 14.2+) and analyzes it on-device. Audio is never recorded or sent anywhere. Beyond loudness, it follows:

- **24 frequency bands**, bass to treble
- **The lead melody's pitch**, so effects swell where the melody is
- **Drum hits** (kick, snare, hi-hat) and **note attacks** from any instrument, so songs without drums still get rhythm
- **How bright the sound is**, which shifts the colors between warm and airy

All of it shows up in:

- **The closed notch**: the small bars next to the album art move with the music.
- **Behind the player** when the notch is open, with 7 styles: floating particles, aurora, pulse glow, beat ripples, silk lines, spectrum bars with falling peak caps, and warp speed.
- **Across the menu bar**, with 11 styles that start from the notch: spread from notch, spectrum silhouette, LED meter, 3D helix, 3D blocks, flowing wave, heartbeat line, beat comets, notch ripples, bass glow, and full-height bars. An intensity slider controls how strong they are. The effects never block clicks, and they pause when the menu bar is hidden or the screen is off.
- **A menu bar icon** with a tiny spectrum. Click it to play or pause.

**Colors**: pick vivid colors taken from the album art, monochrome, or your own 1–5 color gradient (with presets). Every visualizer uses the same palette.

The first time, macOS asks for **System Audio Recording** access. Without it, visualizers fall back to a simple animation.

### Menu bar icons hidden by the notch

On a crowded menu bar, macOS hides icons behind the notch. Perch's **Menu Bar** tab lists those hidden icons and opens their menus. This needs **Accessibility** access.

### Smaller things

- The open notch sits flush with the top of the screen, even before onboarding finishes.
- A Dock icon appears while onboarding is open, so its window can always be found. Reopening Perch.app shows Settings.
- The Now Playing helper process exits with Perch, even after a force quit.

All of these are in **Settings → Visualizer** and **Settings → General**.

## Planned

- [x] Real audio visualizer driven by system audio
- [x] Visualizers in the menu bar, toggleable in Settings
- [x] Show menu bar icons hidden by the notch
- [ ] Better web music support (Zing MP3, NhacCuaTui, SoundCloud…), with a browser extension for sites that don't report what's playing
- [ ] Real menu bar icon images in the Menu Bar tab
- [ ] Perch's own app icon
- [x] Releases with automatic updates (DMG, Homebrew, Sparkle)
- [ ] Developer ID signing and notarization
- [ ] More widgets beyond music

## Building from source

Requirements: **macOS 15.6+** and **Xcode 26+**.

```bash
git clone https://github.com/trieuluan/perch-mac.git
cd perch-mac
open boringNotch.xcodeproj
```

Then press `Cmd + R` in Xcode.

### Keep permissions across rebuilds (optional)

By default, Debug builds are signed ad-hoc, so macOS forgets Accessibility and other permissions after every build. To avoid that, create `Configuration/Local.xcconfig` (it's gitignored) with your team:

```
DEVELOPMENT_TEAM = YOURTEAMID
CODE_SIGN_IDENTITY[sdk=macosx*] = Apple Development
```

A free Personal Team works.

### Code layout

Perch-specific code lives in `boringNotch/Perch/` (and `BoringNotchXPCHelper/MenuBarItemsHelper.swift`), with small hooks in upstream files. Internal folder, target and scheme names still say `boringNotch`. Both choices keep upstream changes merging cleanly.

## Releasing

Releases are built and published from a Mac, with no CI secrets:

```bash
Configuration/release/release.sh 1.1.0            # dry run: build, DMG, appcast, cask
Configuration/release/release.sh 1.1.0 --publish  # tag, GitHub release, Homebrew tap
```

The script uses your `gh` login and the Sparkle EdDSA key stored in your Keychain under the account `perch` (created with Sparkle's `generate_keys --account perch`). Back that key up: without it, existing installs can't verify future updates. The appcast is attached to each GitHub release, and the app reads it from `releases/latest/download/appcast.xml`.

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
