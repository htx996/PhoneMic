# PhoneMic

<p align="center">
  <img width="344" height="288"
       alt="截屏2026-09-21 15 14 49"
       src="https://github.com/user-attachments/assets/77bc1b8f-7a67-47c3-9fb8-9e6f01a3132a" />
</p>

PhoneMic is a native iPhone + macOS app that lets an iPhone act as a Mac microphone over local Wi-Fi, with the Mac-side USB proxy integration point prepared for a bundled helper.

Current MVP path:

```text
iPhone microphone
-> AVAudioSession + AVAudioEngine
-> 48 kHz mono Float32 PCM packets
-> Network.framework TCP connection discovered by Bonjour or forwarded by the bundled USB proxy
-> PhoneMic pairing / authenticated stream and status handshake
-> macOS menu bar receiver
-> jitter buffer / ring buffer
-> BlackHole 2ch output
-> BlackHole input automatically selected as the system/app microphone
```

The custom Core Audio HAL driver is intentionally reserved behind `MicrophoneOutputEngine` for phase 2. The first runnable version uses BlackHole because HAL driver signing, notarization, installation, and `coreaudiod` lifecycle work can otherwise block the MVP.

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

## iPhone Launch Crash Fix

If an earlier build opened and immediately quit on iPhone, rebuild with the current project. The root cause was the `PhoneMicCore.framework` install name: it was emitted as `/Library/Frameworks/PhoneMicCore.framework/PhoneMicCore`, which iOS cannot load from inside an app bundle. The framework target now uses `@rpath/PhoneMicCore.framework/PhoneMicCore`, matching the embedded copy in `PhoneMicIOS.app/Frameworks`.

In Xcode, use Product > Clean Build Folder once, then run `PhoneMicIOS` on the iPhone again.

## App Icon

Generated icon candidates are in `outputs/icon-options/`:

- `PhoneMic-Icon-A.png` - bright blue glass microphone with connection orbit.
- `PhoneMic-Icon-B.png` - darker professional microphone mark.
- `PhoneMic-Icon-C.png` - microphone with subtle phone-to-desktop connection.
- `PhoneMic-Icon-D.png` - abstract microphone and sound rings.
- `PhoneMic-Icon-C-Flat.png` - earlier flat illustration redesign kept as a design archive.
- `PhoneMic-Icon-Preview.png` - 2x2 comparison sheet.

The Xcode project currently uses the AppIcon images in `Apps/iOS/PhoneMicIOS/Assets.xcassets/AppIcon.appiconset`.
Run `swift script/generate_macos_icon.swift` to regenerate both the macOS `.icns` and the matching iOS AppIcon PNGs from the same blue microphone artwork.

The iPhone advertises `_phonemic._tcp` using Bonjour on a fixed PhoneMic audio port. The Mac app discovers it and connects automatically.
The Mac menu bar app only auto-connects to paired iPhones. If an unpaired iPhone is visible, click `Pair` in the Mac panel, confirm the 6-digit code on iPhone, and PhoneMic will remember the trusted relationship. If more than one PhoneMic iPhone is visible on the local network, use the `Device` menu in the Mac panel to choose the intended phone.

Pairing secrets are stored in Keychain on both Mac and iPhone. Older development builds that stored trusted devices in preferences are migrated automatically on first launch.

The Mac app bundles a `phonemic-usbproxy` helper and can manage it from the menu bar panel. The helper talks to macOS `usbmuxd` directly, so wired mode does not require Homebrew, `iproxy`, or libimobiledevice.

## Use as a System Microphone

1. Start the Mac app.
2. Start streaming from the iPhone app.
3. Pair the iPhone the first time: click `Pair` on Mac and confirm the matching code on iPhone.
4. Confirm the Mac menu bar status shows `正在发送到 Mac` and `Output` is `BlackHole 2ch`.
5. Open the app that needs the microphone.
6. Select `BlackHole 2ch` as that app's microphone/input device.

PhoneMic now tries to select `BlackHole 2ch` as the global macOS input automatically on launch. If it switched from another input, the menu bar panel provides `恢复原输入`.

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

- `自动` chooses a lower prebuffer for USB and a safer one for Wi-Fi.
- `低延迟` keeps prebuffer low for close-range use.
- `稳定` raises prebuffer for noisy networks.

The `自动校准` button listens to the current stream for a few seconds and adjusts gain/voice processing toward an audible, non-clipping level. PhoneMic also applies lightweight clipping and weak-voice protection while running.

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
