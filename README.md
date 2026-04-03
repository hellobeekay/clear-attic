# Clear Attic

A minimal macOS menu bar app that scans your Mac for junk and frees up disk space — no clutter, no subscriptions.

---

## What it does

Clear Attic lives in your menu bar and scans common locations where storage quietly accumulates:

| Category | What it finds |
|---|---|
| **Dust** | `~/Library/Caches` — app caches (Adobe, Spotify, pip, Homebrew…) |
| **Old Notes** | `~/Library/Logs` — log files |
| **Blueprints** | Xcode DerivedData and Archives |
| **Toy Models** | iOS Simulator device images |
| **Forgotten Boxes** | `node_modules` directories in your projects |
| **Packed Bags** | `.dmg`, `.pkg`, `.zip` files in Downloads |
| **Junk Pile** | Contents of the Trash |

Only items over **100 MB** are shown. Select what you want gone, hit **Clear All** — files go to Trash (recoverable) or are removed directly.

---

## Features

- **Menu bar only** — no Dock icon, no window
- **Auto Clean** — schedule a weekly sweep (choose day + hour)
- **Launch at Login** — via `SMAppService`
- **Sound feedback** — plays the Glass chime on completion
- **Dark UI** — always dark popover, 223 px wide

---

## Requirements

- macOS 13.5+
- Xcode 15+ to build
- No App Sandbox (required for full filesystem access)

---

## Build & Run

1. Clone the repo
2. Open `clear attic.xcodeproj` in Xcode
3. Set your development team in Signing & Capabilities
4. Build & Run (`⌘R`)

The app appears as a paintbrush icon in the menu bar.

---

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌘S` | Start scan |
| `⌘Q` | Quit |
| `⌘⌫` | Clear selected items |

---

## Privacy

All scanning happens locally on your machine. No data leaves your Mac.
