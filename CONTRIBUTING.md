# Contributing

Thanks for helping out! MDReader is intentionally small: it's a **reader**, not an editor, and every feature has to earn its weight. If you're planning something big, open an issue first so we can agree on the approach.

## Setup

You need macOS 13+, the Xcode Command Line Tools (`xcode-select --install`), and Node.js only if you touch the renderer tests.

```bash
./build.sh                          # builds build/MDReader.app
open build/MDReader.app docs/sample.md
cd tests && npm install && npm test # renderer tests
```

## Where things live

- **Native app** (`Sources/MDReader/`): SwiftUI and AppKit, with no third-party Swift packages. The app owns one `WKWebView`, shared by all tabs, in `ReaderController.swift`.
- **Renderer** (`Resources/web/`): `app.js` turns Markdown into HTML with marked, cleans it, and adds the extras (alerts, anchors, math, diagrams, find). `style.css` holds the light, dark and print themes.
- **Vendored libraries** (`Resources/web/vendor/`): pinned and unmodified. If you update one, update `THIRD_PARTY_NOTICES.md` too.
- **Icon** (`scripts/make_icon.swift`): drawn in code. Run `./scripts/make_icon.sh` after changing it.

## Guidelines

- Keep the app lightweight. Load anything heavy lazily, the way KaTeX and Mermaid only load when a document uses them.
- Add a test in `tests/render.test.js` for renderer changes.
- Match the surrounding code style. Run `swift build` and make sure it has no warnings.
- Everything the page gets from a document is untrusted. Keep `sanitize()` strict.

## Releasing

Push a tag such as `git tag v1.1.0 && git push --tags`. The Release workflow then builds a universal app, attaches a .dmg and a .zip to a GitHub release, and updates the Homebrew cask if `HOMEBREW_TAP_TOKEN` is set.
