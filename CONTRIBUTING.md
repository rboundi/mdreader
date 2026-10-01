# Contributing

Open an issue before starting a large change.

## Build and test

Needs macOS 13 or later and the Xcode Command Line Tools. The tests need Node.js.

```bash
./build.sh
open build/MDReader.app docs/sample.md
cd tests && npm install && npm test
```

## Layout

- `Sources/MDReader/`: the app, in SwiftUI and AppKit
- `Resources/web/`: the renderer (`app.js`, `style.css`)
- `Resources/web/vendor/`: bundled libraries, listed in `THIRD_PARTY_NOTICES.md`
- `Resources/AppIcon.icon`: the icon, written by `scripts/make_icon.sh` (Xcode 26 or later)
- `tests/render.test.js`: renderer tests

## Rules

- No new dependencies without an issue first
- Load large libraries only when a document needs them
- Renderer changes come with a test
- Everything rendered goes through `sanitize()`

## Releasing

```bash
scripts/release.sh 1.2.3
```

Needs Xcode, a Developer ID Application certificate, and a notarytool profile named `mdreader-notary`:

```bash
xcrun notarytool store-credentials mdreader-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-id>
```
