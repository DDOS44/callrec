# Task 0 spike results (2026-09-18, macOS 26.5, M-series MacBook Air)

- Permission: the process tap needs the TCC "System Audio Recording Only" grant. A bare CLI never prompts; embedding Info.plist (NSAudioCaptureUsageDescription) + calling TCCAccessRequest(kTCCServiceAudioCapture) makes the responsible app (Terminal) appear in System Settings. User still had to toggle it ON manually once. Under launchd the binary itself will be the responsible process.
- Trigger process: **`com.apple.avconferenced`** appears in the Core Audio process list with `out=true in=true` exactly when a Continuity phone call connects, and disappears on hang-up. `callservicesd` did not appear. Set `Config.triggerBundleIDs = ["com.apple.avconferenced"]`.
- Far-side capture: global tap during a live call, user silent, other party talking → RMS 0.00–0.11 with speech-shaped peaks. **Tap design confirmed. BlackHole fallback not needed.**
- Announcement to the other party: pending confirmation from Anurag (expected: none).
