# Contributing to Focal

Thanks for helping. Focal is a one-person project with a clear shape, so a short chat first saves everyone time:
for anything bigger than a bug fix, open an issue describing what you want to add.

## How

1. **Fork** the repo on GitHub, then `git clone` your fork.
2. **Branch**, one per change: `git checkout -b fix-pdf-crop`.
3. **Build and test** (below). Both must pass.
4. **Push** the branch to your fork and open a **pull request** against `main`. Say what changed and why.

Nothing reaches the downloadable app until it is reviewed, merged and released.

## Build

Needs Xcode with Swift 6 on **macOS 27+, Apple silicon**.

```bash
swift build                          # compile check
swift test                           # unit tests, under a second
CONFIG=debug scripts/build-app.sh    # "Focal Dev.app", a separate app that won't touch your installed Focal
scripts/uitest.sh steps.json         # drive Focal Dev through a JSON script
```

[CLAUDE.md](CLAUDE.md) is the real developer guide: code layout, the UI test harness, and a list of
"decisions with a bug behind them". **Read the relevant entry before changing window placement, undo, text
saving or Markdown rendering**: each one exists because the obvious version broke.

## Conventions

- Swift 6 strict concurrency, AppKit; SwiftUI only for Settings. No new dependencies without asking.
- Match the surrounding code. Keep a change to what it needs; no drive-by refactors.
- A bug fix comes with a test that fails without it (Swift Testing, in `Tests/`).
- Don't change the non-negotiable behaviour listed at the top of CLAUDE.md (windows open centered on the main
  display, no scroll bars on images, one remembered text size, and so on).
- Only claim what you ran. If a change touches the UI, say how you checked it.
- Commit with a message that says why. Don't commit builds, secrets or large binaries.

## Licence

Focal is MIT with the [Commons Clause](LICENSE): free to use, change and share, not to sell. By opening a pull
request you agree your contribution is released under the same licence.
