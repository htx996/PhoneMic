# PhoneMic iOS App

This folder contains the iPhone app source for the MVP. The repository root now includes `PhoneMic.xcodeproj`, so the app no longer has to be assembled manually.

From the repository root, build the iOS target with:

```bash
./script/build_ios.sh
```

The script uses `/Applications/Xcode.app` through `DEVELOPER_DIR` and does not change global `xcode-select`. It produces an unsigned compiler-validation build, not a direct-install iPhone package. If Xcode reports that iOS is not installed, install the iOS platform from Xcode > Settings > Components and rerun the script.

To run it on an iPhone:

1. Open `PhoneMic.xcodeproj` in Xcode.
2. Select the `PhoneMicIOS` scheme.
3. Select a physical iPhone.
4. Set your Apple development team if signing is not already configured.
5. Build and run.
6. Tap `Start Streaming`.

For command-line signed builds after Xcode has an Apple Development certificate:

```bash
DEVELOPMENT_TEAM=YOURTEAMID ./script/build_ios_device_signed.sh
```

For a connected-device install:

```bash
DEVELOPMENT_TEAM=YOURTEAMID DEVICE_ID=YOUR_DEVICE_ID INSTALL=1 ./script/build_ios_device_signed.sh
```

The app advertises `_phonemic._tcp` over Bonjour and sends 48 kHz mono Float32 PCM packets over TCP to the Mac app.
