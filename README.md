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
| **3-finger swipe down** | Toggles the Apple Music HUD: album art, track info, progress, previous/play-pause/next, favorite ♥, add to library, add-to-playlist menu, shuffle. Auto-hides after ~6s; hovering pins it. If the app carousel is visible, it lifts above the music pane. |

The ring's order is persistent: it only re-sorts (most-recently-used first) when you switch apps some other way — Dock, Cmd-Tab, a click — or an app launches or quits. That's what makes "one swipe right, one swipe left" reliably toggle between two apps.

## No trackpad? (clamshell mode)

Hold **⌥ Option and scroll** on a Magic Mouse: horizontal swipes glide the ring exactly like the trackpad gesture, a downward swipe opens the music HUD, and those scrolls never reach the page behind. Classic wheel mice work too (⌥ + wheel steps the ring). The modifier is configurable (⌥/⌘/⌃) and the feature can be disabled in Settings → Gesture. Both HUDs are fully mouse-operable once open — click an icon to jump, click the music controls, hover to pin.

## Setup (one-time)

Both items live in the Settings window's **Status** section, with buttons that open the right System Settings panes:

1. **Free up the 3-finger gesture**: System Settings → Trackpad → More Gestures → set "Swipe between full-screen applications" to **Four Fingers** (or Off), and keep Three-Finger Drag off (Accessibility → Motor → Pointer Control → Trackpad Options). Otherwise macOS reacts to the same swipes.
2. **Grant Accessibility** (Privacy & Security → Accessibility): used to tell real windows from phantom ones (apps like Notes keep an invisible window after you close the last one) and to unminimize windows when switching. Without it AppGlide still works, but window detection is less accurate.
3. **Allow Automation for Music** (prompted on first use of the music HUD): AppGlide controls Apple Music via Apple Events. Recovery lives in Privacy & Security → Automation; the HUD itself shows a shortcut button if permission is missing.

## Settings

Open via the gear on the HUD or the menu-bar icon → Settings…

- **Status** — the two setup checks above, live.
- **Gesture** — invert swipe direction; swipe distance (sensitivity — shorter = more sensitive); glide step distance; haptic feedback on/off; modifier+scroll (Magic Mouse) on/off with modifier choice.
- **Music** — the swipe-down music HUD gesture on/off.
- **Minimized Apps** — when all of an app's windows are minimized: unminimize on switch, or skip the app entirely.
- **Excluded Apps** — check any app to banish it from the ring and HUD.
- **HUD** — how long both HUDs stay visible after the last interaction (they always dismiss together).
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
