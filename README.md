# Ghost

A focus timer for the Mac menu bar. Say what you're focusing on, pick what counts, and Ghost keeps you there.

## Start a round

Press **Option + Space** (or click the menu bar ring, then **Start focus…**). A small panel asks:

- **What are you focusing on?** Type it, or pick a suggestion: today's items from the Today app, your presets, or recent focuses.
- **Counts as focus:** the apps that count. The app you were in is added for you; add more with **Add app**. No apps means any app counts.
- **Sites that count in the browser:** when a browser counts, list the sites that count (like `ixl.com`). Only the domain is checked, never the full link. No sites means any page counts.
- **Save as preset** keeps the setup for one-click starts.

Leave what counts and, after a grace period, the screen slowly **dims** (or **blurs**) until you come back. Nothing is blocked; it nudges.

## Control a round

| | |
|---|---|
| **⌥ Space** | Start, pause or resume. After a round ends: go on |
| **⌥ ⇧ Space** | End the round (it still counts) |
| Menu bar or window | **Add 5 minutes**, **Take a break now**, **Skip break** |

When a round ends, a panel drops in from the top: **Start break**, **+5 min** or **End** (or turn on automatic breaks and focus in Settings). A sound of your choice plays, with an optional notification.

The menu bar shows a small progress ring and the minutes left (or just one of them). A thin clay line at the screen edge shows the round: **Sand** drains along the top, **Tide** grows along the bottom while you stay focused.

## The window

- **Overview:** today's focus time, the round in progress with its controls, the last 7 days, a 12-week heatmap and streak, time by focus, top apps and top sites.
- **Presets:** your saved setups, with Start and delete.
- **Settings:** rhythm (Classic 25/5, Deep 50/10, Sprint 15/3, or custom), automatic breaks, dim or blur and its strength, grace period, sounds, notifications, menu bar style, edge line, appearance, open at login.

## Works with Today

Ghost reads today's plan from Today's files (`~/Downloads/claude/today_status.json`, or `schedule.md`) for suggestions, and writes `ghost_status.json` next to them: focus minutes today, by focus, and for the last 7 days. Use another folder with:

```sh
defaults write io.github.o1ie12.ghost schedulePath ~/path/to/schedule.md
```

## Privacy and weight

Ghost reacts to app switches and runs one slow timer (every 2 s) only during a round. Browser sites are read only when a focus has sites (or site tracking is on in Settings), and macOS asks your permission first. Stats stay on your Mac in `~/Library/Application Support/Ghost/`.

## Build

Needs only the Xcode Command Line Tools (no Xcode). macOS 14 or later, Apple silicon.

```sh
./build.sh            # builds build/Ghost.app
./build.sh --install  # builds, copies to /Applications and opens it
```

The icon is drawn by `swift icon/make_icon.swift`.
