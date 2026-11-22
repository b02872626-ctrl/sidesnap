# Sidesnap

A free macOS menu-bar app for screenshots. Every capture goes to your
clipboard and onto a shelf at the right edge of your screen, where you can
find it again, drag it into any app, or mark it up.

**Download:** https://sidesnap.typewellapp.workers.dev

- **⌥⇧S** select an area (press Space to pick a window instead), **⌥S** the
  whole screen, **⌥⇧T** copy the text or QR link in an area. You can change
  them in Settings.
- A small card in the corner after each capture: click to copy again, drag
  it anywhere, or let it tuck into the shelf by itself.
- The shelf: point at the right edge of the screen to fan out your recent
  screenshots. Search them by the words inside them.
- An editor with arrows, boxes, text, speech bubbles, numbered steps, blur,
  highlight, pen and crop. Edits stay changeable, and the original is kept.
- Pin the ones you want to keep. The rest are cleared after 30 days (you can
  change this).
- Open at login, and one-click updates.

Requires macOS 14 or later. Apple silicon and Intel.

## Privacy

- **Your screenshots never leave your Mac.** They're kept in
  `~/Library/Application Support/Sidesnap/Shelf` until they're cleared or you
  remove them.
- **Reading the text in screenshots** (for search and Copy Text) happens on
  your Mac with Apple's Vision framework (`TextGrab.swift`). You can turn it
  off in Settings › Privacy.
- **Pause Shelf History** (in the menu) copies captures to the clipboard and
  keeps nothing.
- **The only network request is the update check:** once a day (you can turn
  it off) it downloads the update feed. Nothing about you or your
  screenshots is sent.
- No analytics, no account, no tracking.

The code is all here, so you can check this yourself. See
[SECURITY.md](SECURITY.md) to report a problem.

## Build it yourself

You only need Apple's command-line tools (`xcode-select --install`); Xcode
isn't needed.

```bash
git clone https://github.com/b02872626-ctrl/sidesnap.git
cd sidesnap
./build.sh            # makes build/Sidesnap.app
./build.sh --install  # also copies it to ~/Applications and opens it
```

The first build downloads the [Sparkle](https://sparkle-project.org) update
framework (2.10.1, checked against a fixed checksum) into `Vendor/`.

The first time Sidesnap captures, macOS asks to allow **Screen Recording**:
System Settings › Privacy & Security › Screen & System Audio Recording ›
turn on Sidesnap. Your own builds get a plain local signature, so macOS may
ask again after every rebuild. To avoid that, make a self-signed
certificate once: Keychain Access › Certificate Assistant › Create a
Certificate…, name it `Sidesnap Developer`, identity type **Self-Signed
Root**, certificate type **Code Signing**. `build.sh` uses it when it's there.

## Make your own version

Fork it and change whatever you like. The code is MIT licensed. Before you
share your version with other people:

1. **Give it your own name and icon.** The licence covers the code, not the
   Sidesnap name or icon. Change `CFBundleName` and `CFBundleDisplayName` in
   `Resources/Info.plist`, and the icon (`tools/make_icon.swift` draws it).
2. **Use your own app ID.** Change `CFBundleIdentifier` (`app.sidesnap.mac`)
   in `Resources/Info.plist`, plus `--identifier` in `tools/sign_app.sh`.
3. **Use your own update feed, or none.** Otherwise your app would ask for
   Sidesnap's updates.
   - Either point `SUFeedURL` at your own feed and replace `SUPublicEDKey`
     with your own key (Sparkle's `generate_keys`),
   - or delete `SUFeedURL` and `SUPublicEDKey` to turn updates off.

## How the code is organised

| File | What it does |
|---|---|
| `Sources/Sidesnap/App.swift` | App entry, the menu-bar menu, wiring |
| `Sources/Sidesnap/Capture.swift` | Area, window and full-screen capture (ScreenCaptureKit) |
| `Sources/Sidesnap/HotKeys.swift` | Global shortcuts (no Accessibility permission needed) |
| `Sources/Sidesnap/CornerCard.swift` | The card shown after a capture |
| `Sources/Sidesnap/EdgeTab.swift` | The shelf at the right screen edge |
| `Sources/Sidesnap/ShelfStore.swift` | Saving, pinning and clearing screenshots |
| `Sources/Sidesnap/Editor.swift` | The markup editor |
| `Sources/Sidesnap/TextGrab.swift` | On-device text and QR reading (Vision) |
| `Sources/Sidesnap/Settings.swift`, `Prefs.swift` | Settings window and stored settings |
| `Sources/Sidesnap/Onboarding.swift` | First-launch walkthrough |
| `Sources/Sidesnap/Permission.swift` | Screen Recording permission |
| `Sources/Sidesnap/MenuIcon.swift` | The menu-bar icon and its states |
| `Sources/Sidesnap/Updater.swift` | Sparkle updates |
| `Sources/Sidesnap/Migration.swift` | Brings settings over from the old name (Snapshelf) |
| `build.sh`, `release.sh`, `publish.sh` | Dev build, release DMG, publish an update |
| `tools/` | Signing, Sparkle download, icon drawing |
| `site/`, `worker/`, `migrations/` | The download page (Cloudflare Worker with a per-day download count) |
| `docs/MAINTAINING.md` | Notes for the official app's maintainer |

## Contributing

Sidesnap is open source so you can learn from it and make your own version.
Bug reports and ideas are welcome in
[Issues](https://github.com/b02872626-ctrl/sidesnap/issues). Pull requests
aren't accepted. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

- Code: [MIT](LICENSE)
- Website photo: NASA, public domain (see `site/images/CREDITS.md`)
- The Sidesnap name and icon are not part of the open-source licence.
