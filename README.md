# AppGlide

Switch between macOS apps with a 3-finger trackpad swipe, iPad-style. A lightweight menu-bar utility: the windows of the app you glide to come straight to the front — no Cmd-Tab, no Spaces, no full-screen required.

## Gestures

| Gesture | What it does |
|---|---|
| **Flick** — quick 3-finger swipe left/right | Switches to the next/previous app immediately. Swipe right goes to the previous (older) app; swipe left goes forward. |
| **Glide (scrub)** — swipe and keep fingers down | Steps through one app per detent of travel, with a haptic tick each step. Reverse direction mid-glide to step back. The app under the cursor activates ~¼s after you stop. |
| **Wrap** | The ring is circular — keep going in one direction and you'll come back around. |
| **Hover the HUD** | Pins it open (it normally fades after ~1.5s). |
| **Click a HUD icon** | Jumps straight to that app and pulls it in next to the current one on the ring, instead of rotating everything. |

The ring's order is persistent: it only re-sorts (most-recently-used first) when you switch apps some other way — Dock, Cmd-Tab, a click — or an app launches or quits. That's what makes "one swipe right, one swipe left" reliably toggle between two apps.

## Setup (one-time)

Both items live in the Settings window's **Status** section, with buttons that open the right System Settings panes:

1. **Free up the 3-finger gesture**: System Settings → Trackpad → More Gestures → set "Swipe between full-screen applications" to **Four Fingers** (or Off), and keep Three-Finger Drag off (Accessibility → Motor → Pointer Control → Trackpad Options). Otherwise macOS reacts to the same swipes.
2. **Grant Accessibility** (Privacy & Security → Accessibility): used to tell real windows from phantom ones (apps like Notes keep an invisible window after you close the last one) and to unminimize windows when switching. Without it AppGlide still works, but window detection is less accurate.

## Settings

Open via the gear on the HUD or the menu-bar icon → Settings…

- **Status** — the two setup checks above, live.
- **Gesture** — invert swipe direction; swipe distance (sensitivity — shorter = more sensitive); glide step distance; haptic feedback on/off.
- **Minimized Apps** — when all of an app's windows are minimized: unminimize on switch, or skip the app entirely.
- **Excluded Apps** — check any app to banish it from the ring and HUD.
- **HUD** — how long it stays visible after the last swipe.
- **General** — pause switching; launch at login.

## Build & install

Requires Xcode 26+, macOS 15+. App Sandbox is off (required by the private multitouch framework), so this is not App Store distributable; it builds and runs locally with a development signature.

```bash
# Debug
xcodebuild -project AppGlide.xcodeproj -scheme AppGlide -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/AppGlide.app

# Release → /Applications
xcodebuild -project AppGlide.xcodeproj -scheme AppGlide -configuration Release -derivedDataPath build build
ditto build/Build/Products/Release/AppGlide.app /Applications/AppGlide.app
open /Applications/AppGlide.app
```

## How it works

[OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport) (a wrapper over the private `MultitouchSupport.framework`) streams raw trackpad touches → `SwipeGestureRecognizer` (pure state machine: 3-finger horizontal detection, detents, finger-flicker grace) → `GestureMonitor` → `AppSwitcher` (persistent MRU session, commit-on-settle activation, Accessibility-based window filtering) → `SwitcherOverlay` (non-activating click-through-until-hovered NSPanel drawing the 3D ring HUD). The app is `LSUIElement` — menu-bar only, no Dock icon. It installs no event taps and synthesizes no keystrokes, so Cmd-Tab and AltTab are untouched.
