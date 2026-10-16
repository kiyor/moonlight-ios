# Moonlight iOS — kiyor fork

An unofficial fork of [moonlight-ios](https://github.com/moonlight-stream/moonlight-ios) that ports a set of quality-of-life features from [Axixi2233/moonlight-android](https://github.com/Axixi2233/moonlight-android) (阿西西版) to iPhone. Not affiliated with or supported by the Moonlight project — please don't file issues for this fork upstream.

> **Status: experimental.** Everything below builds and launches on device; most features have **not** yet been through a full real-world streaming test. Expect rough edges. The in-stream menu is currently Chinese-only.

### What's added

All controls live in a side panel you pull in from the right edge during a stream.

| Area | Feature |
|---|---|
| Panel | Thumb rail of common keys + tile grid (tap to toggle, long-press for sub-page), self-drawn controls |
| Keyboard | Windows shortcut combos (Explorer, desktop, Task Manager, copy/paste…); user-defined combos (add / delete / persisted) |
| Stats | Overlay off / compact / detailed; detailed items individually toggleable (resolution, fps, codec, bitrate, RTT, loss, receive, decode time, host latency) |
| Decode | Optional VideoToolbox decode path to measure real decode time (switchable back to upstream layer decode) |
| Quality | Change resolution / frame rate / bitrate mid-stream (reconnects; current session only) |
| Touch | Switch trackpad / direct-touch mid-stream; on-screen mouse buttons (L/M/R + wheel); custom draggable key layout incl. WASD stick |
| Gamepad | Gamepad-as-mouse (left stick cursor, right stick wheel, A/B/X clicks); audio-driven haptics (bass level → impact feedback) |
| Session | Auto-reconnect when returning from background |
| Display | Portrait streaming (landscape / follow device / portrait) with a shortcut bar under the video; external display output (HDMI / AirPlay) with the phone kept as touchpad |

### Building this fork

```sh
git clone --recursive https://github.com/kiyor/moonlight-ios.git
cd moonlight-ios
TEAM=<your Apple Team ID> BUNDLE_ID=<your.bundle.id> scripts/run-device.sh
```

`scripts/run-device.sh` builds Debug, installs and launches on the first reachable paired iPhone. Optional: `MODEL=iPhone17,2` to pick a device, `DISPLAY_NAME=...` to rename the home-screen icon. Values can be kept in `scripts/local.env` (gitignored). Building from Xcode as described below also works.

### Credits & license

- [moonlight-stream/moonlight-ios](https://github.com/moonlight-stream/moonlight-ios) — the upstream client this fork is based on.
- [Axixi2233/moonlight-android](https://github.com/Axixi2233/moonlight-android) — feature and side-panel layout reference. Features were re-implemented for iOS; no Android code is reused directly.
- Licensed under GPL-3.0, same as upstream — see [LICENSE.txt](LICENSE.txt).

---

*Original upstream README follows.*

# Moonlight iOS/tvOS

[![CI](https://github.com/moonlight-stream/moonlight-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/moonlight-stream/moonlight-ios/actions/workflows/ci.yml)

[Moonlight for iOS/tvOS](https://moonlight-stream.org) is an open source client for [Sunshine](https://github.com/LizardByte/Sunshine) and NVIDIA GameStream. Moonlight for iOS/tvOS allows you to stream your full collection of games and apps from your powerful desktop computer to your iOS device or Apple TV.

Moonlight also has a [PC client](https://github.com/moonlight-stream/moonlight-qt) and [Android client](https://github.com/moonlight-stream/moonlight-android).

Check out [the Moonlight wiki](https://github.com/moonlight-stream/moonlight-docs/wiki) for more detailed project information, setup guide, or troubleshooting steps.

[![Moonlight for iOS and tvOS](https://moonlight-stream.org/images/App_Store_Badge_135x40.svg)](https://apps.apple.com/us/app/moonlight-game-streaming/id1000551566)

## Building
* Install Xcode from the [App Store page](https://apps.apple.com/us/app/xcode/id497799835)
* Run `git clone --recursive https://github.com/moonlight-stream/moonlight-ios.git`
  *  If you've already clone the repo without `--recursive`, run `git submodule update --init --recursive`
* Open Moonlight.xcodeproj in Xcode
* To run on a real device, you will need to locally modify the signing options:
    * Click on "Moonlight" at the top of the left sidebar
    * Click on the "Signing & Capabilities" tab
    * Under "Targets", select "Moonlight" (for iOS/iPadOS) or "Moonlight TV" (for tvOS)
    * In the "Team" dropdown, select your name. If your name doesn't appear, you may need to sign into Xcode with your Apple account.
    * Change the "Bundle Identifier" to something different. You can add your name or some random letters to make it unique.
    * Now you can select your Apple device in the top bar as a target and click the Play button to run.
