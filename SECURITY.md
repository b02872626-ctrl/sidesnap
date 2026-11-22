# Security and privacy

Sidesnap can see your screen when you capture, so it must be trustworthy.
These are its promises:

- Screenshots never leave your Mac. They're saved only in
  `~/Library/Application Support/Sidesnap/Shelf` (and in a folder you choose,
  if you turn on saving files), and cleared after the time set in Settings.
- The screen is only read when you ask for a capture (`Capture.swift`).
- Reading the words in a screenshot happens on your Mac with Apple's Vision
  (`TextGrab.swift`), and can be turned off.
- No analytics, no account, no tracking.
- The only network request is the update check: once a day, you can turn it
  off, and nothing about you is sent. Updates only install if they're signed
  with Sidesnap's update key.

## Reporting a problem

If you find something that breaks one of these promises, or any other
security problem, **please report it privately**, not in a public issue:

- Go to the repo's **Security** tab › **Report a vulnerability**,
  or use this direct link: https://github.com/b02872626-ctrl/sidesnap/security/advisories/new

Please include what you found, how to reproduce it, and the Sidesnap and
macOS versions. You'll get a reply as soon as possible, and fixes ship as a
normal update.

Only the latest version gets fixes.

## Versions published by others

Forks are made and published by other people. These promises only cover the
official Sidesnap from https://sidesnap.typewellapp.workers.dev and this repo.
