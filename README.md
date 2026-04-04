# Clear Attic

A minimal macOS menu bar app that scans your Mac for junk and frees up disk space — no clutter, no subscriptions.

---

## Branches

Use the branches with one clear rule:

- `main` is the development branch
- `production` is the branch that matches the build shared with testers

### Recommended workflow

1. Make changes on `main`
2. Test on `main`
3. Merge `main` into `production` when you want a new tester build
4. Build, export, zip, and publish only from `production`
5. Create a GitHub Release/tag for each shared build

### What each branch means

- `main`: ongoing work, experiments, UI ideas, internal-only flows like `See how it works`
- `production`: stable tester build, only changes you are ready to ship

This keeps two records clear:

- what you are currently building
- what testers are actually using

---

## What it does

Clear Attic lives in your menu bar and scans common locations where storage quietly accumulates:

| Category | What it finds |
|---|---|
| **Dust** | `~/Library/Caches` and common local package/runtime caches |
| **Old Notes** | `~/Library/Logs` — log files |
| **Blueprints** | Xcode DerivedData, Archives, and device support files |
| **Toy Models** | iOS Simulator device images |
| **Forgotten Boxes** | `node_modules` and developer package caches |
| **Packed Bags** | Large installer/archive files in Downloads and device backups |
| **Junk Pile** | Contents of the Trash |

Only items over the current scan threshold are shown. Select what you want gone, hit **Clear All** — files are moved to Trash first when possible.

---

## Features

- **Menu bar only** — no Dock icon, no window
- **Auto Clean** — schedule a weekly sweep (choose day + hour)
- **Launch at Login** — via `SMAppService`
- **Sound feedback** — plays the Glass chime on completion
- **Dark UI** — always dark popover, 223 px wide

---

## Requirements

- macOS 12+
- Xcode 15+ to build
- No App Sandbox (required for full filesystem access)

---

## Build & Run

1. Clone the repo
2. Open `clear attic.xcodeproj` in Xcode
3. Set your development team in Signing & Capabilities
4. Build & Run (`⌘R`)

The app appears as a paintbrush icon in the menu bar.

## Releasing A Tester Build

1. Switch to `production`
2. Pull the latest remote changes
3. Archive/export from Xcode
4. Zip the exported `.app`
5. Upload the zip to GitHub Releases
6. Share the GitHub Release link

Do not build tester releases from `main`.

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
