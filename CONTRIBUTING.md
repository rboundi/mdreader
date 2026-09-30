# Contributing

MDReader is a reader, not an editor. For larger changes, open an issue first.

## Setup

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). The renderer tests need Node.js.

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

- Load large dependencies only when needed, as with KaTeX and Mermaid.
- Add a test in `tests/render.test.js` for renderer changes.
- `swift build` should have no warnings.
- Treat document content as untrusted. Keep `sanitize()` strict.

## Releasing

Push a tag such as `git tag v1.1.0 && git push --tags`. The Release workflow builds a universal app, attaches a .dmg and .zip to a GitHub release, and updates the Homebrew cask if `HOMEBREW_TAP_TOKEN` is set.
