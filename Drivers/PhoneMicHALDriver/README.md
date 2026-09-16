# PhoneMic HAL Driver

The MVP uses BlackHole 2ch as the virtual microphone bridge:

`iPhone -> PhoneMic Mac receiver -> BlackHole output side -> BlackHole input side -> apps`

This folder reserves the phase-2 module for a self-hosted Core Audio Server Plug-in. A production HAL driver has extra constraints that are intentionally outside the MVP path:

- signed and notarized installer
- system audio plug-in installation under `/Library/Audio/Plug-Ins/HAL`
- lifecycle management through `coreaudiod`
- user-facing uninstall/restart flow
- stricter crash isolation than the menu bar app

The app already talks to audio output through the `MicrophoneOutputEngine` protocol. `HALDriverOutputEngine` is the reserved implementation point for replacing BlackHole without changing the network receiver, jitter buffer, or UI model.
