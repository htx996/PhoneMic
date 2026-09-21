<h1 align="center">PhoneMic</h1>

<p align="center">
  <img width="344" height="288"
       alt="截屏2026-09-21 15 14 49"
       src="https://github.com/user-attachments/assets/77bc1b8f-7a67-47c3-9fb8-9e6f01a3132a" />
</p>

PhoneMic is a native iPhone + macOS app that lets an iPhone act as a Mac microphone over local Wi-Fi, with the Mac-side USB proxy integration point prepared for a bundled helper.

## Project Structure

- `Package.swift` - SwiftPM package for shared code, tests, and the macOS menu bar app.
- `Sources/PhoneMicCore` - packet format, constants, trusted-peer storage, level metering, ring buffer, jitter buffer.
- `Sources/PhoneMicMac` - macOS SwiftUI menu bar app, Bonjour browser, TCP receiver, USB proxy manager, BlackHole output.
- `Sources/PhoneMicSelfTest` - lightweight self-test executable for environments without XCTest.
- `Apps/iOS/PhoneMicIOS` - iOS SwiftUI app source using AVAudioSession and AVAudioEngine.
- `Resources/macOS` - macOS app iconset and `PhoneMic.icns` used by the staged app bundle.
- `PhoneMic.xcodeproj` - Xcode project containing the `PhoneMicIOS` iOS app target and `PhoneMicCore` iOS framework target.
- `Drivers/PhoneMicHALDriver` - phase-2 placeholder and integration notes for a custom HAL driver.
- `script/build_and_run.sh` - builds and launches the macOS menu bar app bundle.
- `script/package_macos.sh` - builds `dist/PhoneMic.app`, creates a development DMG, and writes checksums/version metadata.
- `script/generate_macos_icon.swift` - regenerates the macOS rounded app icon and `PhoneMic.icns`.
- `script/build_ios.sh` - builds the iOS app with `/Applications/Xcode.app` without changing global `xcode-select`.
- `script/typecheck_ios.sh` - checks iOS Swift source against the iPhoneOS SDK when Xcode platform components are not ready for a full destination build.
- `script/build_ios_device_signed.sh` - builds, and optionally installs, a signed iPhone build when an Apple Team and signing certificate are configured.
- `script/package_ios_resignable_release.sh` - creates an unsigned Release IPA intended only as a re-signing source.

## Requirements

- macOS 14 or newer for the Mac menu bar app.
- iOS 17 or newer for the iPhone app source.
- BlackHole 2ch installed on the Mac for system microphone fallback.
- Xcode at `/Applications/Xcode.app` is used for iOS builds. The scripts set `DEVELOPER_DIR` locally and do not change global `xcode-select`.
- Xcode's iOS platform component must be installed from Xcode > Settings > Components before `xcodebuild` can target `generic/platform=iOS`.

Install BlackHole 2ch:

```bash
brew install blackhole-2ch
```

After installation, open macOS Audio MIDI Setup once and confirm that `BlackHole 2ch` appears as an audio device.

## Build and Run the Mac App

From the repository root:

```bash
./script/build_and_run.sh
```

The script builds the macOS menu bar product, stages `dist/PhoneMic.app`, stops any previous copy, and opens the fresh app bundle.

For a quick process check:

```bash
./script/build_and_run.sh --verify
```

Run the protocol and buffer self-test:

```bash
swift run PhoneMicSelfTest
```

Create a development DMG:

```bash
./script/package_macos.sh
```

This writes `dist/PhoneMic-dev.dmg`, `dist/version.json`, and `dist/checksums.txt`. This development package is not notarized; formal signing/notarization is intentionally reserved for the later release step.

## Build and Run the iPhone App

Build the Xcode iOS target from the repository root:

```bash
./script/build_ios.sh
```

This is an unsigned generic build for compiler validation. It is not meant to be installed directly on an iPhone.

If Xcode reports that iOS is not installed, open Xcode > Settings > Components, install the iOS platform, and rerun the script. To verify the Swift source against the installed iPhoneOS SDK without a full destination build:

```bash
./script/typecheck_ios.sh
```

To run on a physical iPhone:

1. Open `PhoneMic.xcodeproj` in Xcode.
2. Select the `PhoneMicIOS` scheme.
3. Select your physical iPhone.
4. Set your Apple development team for signing if Xcode asks.
5. Build and run.
6. Tap the microphone circle.
7. Allow microphone access when iOS asks.

You can also use the signed-device script after Xcode has an Apple Development certificate:

```bash
DEVELOPMENT_TEAM=YOURTEAMID ./script/build_ios_device_signed.sh
```

To build for and install to a connected iPhone, pass its device identifier:

```bash
DEVELOPMENT_TEAM=YOURTEAMID DEVICE_ID=YOUR_DEVICE_ID INSTALL=1 ./script/build_ios_device_signed.sh
```

If the script says no signing identity was found, open Xcode > Settings > Accounts, sign in, select your team, and let Xcode create/download an Apple Development certificate. If the script says the device is unavailable, unlock the iPhone, trust this Mac, and enable Developer Mode if prompted.

If tapping start reports that microphone permission is not enabled, open iPhone Settings > Privacy & Security > Microphone and allow PhoneMic, then relaunch the app.

PhoneMic declares the iOS `audio` background mode. After streaming starts, the iPhone can be locked or the app can stay in the background while the microphone remains active. Do not force quit PhoneMic from the app switcher; iOS stops all app work after a force quit.

The iOS app keeps a silent audio output path attached to the microphone input while streaming. This is intentional: it keeps the audio session active when iOS moves the app to the background or the screen locks. PhoneMic also listens for audio interruptions and media service resets, then restarts the audio engine when iOS allows it.

For a re-signing source IPA that avoids Debug-only dylibs:

```bash
./script/package_ios_resignable_release.sh
```

The output `outputs/PhoneMicIOS-resignable-release.ipa` is unsigned. It is for re-signing workflows only, not direct installation.

## Use as a System Microphone

1. Start the Mac app.
2. Start streaming from the iPhone app.
3. Pair the iPhone the first time: click `Pair` on Mac and confirm the matching code on iPhone.
4. Confirm the Mac menu bar status shows `Sending to Mac` and `Output` is `BlackHole 2ch`.
5. Open the app that needs the microphone.
6. Select `BlackHole 2ch` as that app's microphone/input device.

PhoneMic now tries to select `BlackHole 2ch` as the global macOS input automatically on launch. If it switched from another input, the menu bar panel provides `Restore original input`.

If there is no sound in WeChat, Discord, Zoom, or another app, first check the
Mac menu bar status:

- `Output` must be `BlackHole 2ch`.
- If `Output` says `BlackHole 2ch not installed`, the Mac is receiving iPhone
  audio but has no virtual microphone device to expose to apps.
- The macOS Sound input list must include `BlackHole 2ch`. PhoneMic tries to
  select it automatically, but individual apps may still need their own
  microphone setting changed once.
- If the input works but sounds too quiet, raise `Mic gain` in the PhoneMic Mac
  menu bar panel. The default is `+9 dB`, and the output uses a light voice
  filter, automatic voice gain, and limiting to keep speech audible without
  bringing back excessive background noise. Very high manual gain values will
  still raise room noise.
- Existing virtual devices such as remote-control audio drivers may appear in
  Sound settings, but PhoneMic's MVP is wired for BlackHole 2ch.
- `Voice` mode applies high-pass filtering, light noise gating, automatic voice
  gain, and limiting. `Raw` mode keeps the stream minimally processed for
  troubleshooting.

PhoneMic includes three transport presets in the Mac menu bar panel:

- `Auto` chooses a lower prebuffer for USB and a safer one for Wi-Fi.
- `Low latency` keeps prebuffer low for close-range use.
- `Stability` raises prebuffer for noisy networks.

The `Automatic calibration` button listens to the current stream for a few seconds and adjusts gain/voice processing toward an audible, non-clipping level. PhoneMic also applies lightweight clipping and weak-voice protection while running.

## Privacy

- PhoneMic does not record or save audio files.
- PhoneMic does not upload audio to cloud services.
- Audio is streamed only to a paired Mac over local Wi-Fi or the bundled USB proxy path.
- Trusted device secrets are stored in Keychain and are removed when you forget the device.

## MVP Limitations

- Wi-Fi/Bonjour is the currently verified runtime transport.
- The Mac-side USB proxy manager and `phonemic-usbproxy` helper are bundled. Wired mode uses macOS `usbmuxd` locally and does not install or upload anything.
- Latency is estimated from wall-clock timestamps and can be skewed if iPhone/Mac clocks differ.
- The current virtual microphone bridge is BlackHole-compatible output, not a signed PhoneMic HAL device.
- The transport abstraction keeps UDP/QUIC reserved slots, but the default runtime path is authenticated TCP.
- The self-hosted HAL driver remains future work.
