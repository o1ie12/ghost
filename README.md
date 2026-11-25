# Ghost

A minimalist pomodoro focus app for the Mac menu bar.

- **Option + Space** starts a focus round with the app in front. Press again to stop.
- A thin line at the edge of the screen shows the round: **Sand** drains along the top, **Tide** grows along the bottom while you stay focused and washes back when you wander.
- Leave your focus app for more than 10 seconds and the screen slowly **dims** (or **blurs**) until you come back. Nothing is blocked; it just nudges.
- Breaks start on their own. The line refills during a break. Every 4th break is a long one.
- The window (menu bar, then Open Ghost) shows today's focus time, the last 7 days, your streak, focus score and top apps, plus settings.

Light by design: Ghost reacts to app switches and runs one slow timer only during a session. No polling when idle, no screen recording, no extra permissions. Stats stay on your Mac in `~/Library/Application Support/Ghost/rounds.json`.

## Build

Needs only the Xcode Command Line Tools (no Xcode). macOS 14 or later, Apple silicon.

```sh
./build.sh            # builds build/Ghost.app
./build.sh --install  # builds, copies to /Applications and opens it
```

The icon is drawn by `swift icon/make_icon.swift`.
