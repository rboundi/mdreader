<p align="center">
  <img src="docs/icon-256.png" width="128" alt="MDReader icon">
</p>

<h1 align="center">MDReader</h1>

<p align="center">A Markdown reader for macOS.</p>

<p align="center">
  <img src="docs/screenshot-dark.png" width="760" alt="MDReader showing a document with an outline sidebar, math and a diagram in dark mode">
</p>

## Features

**Reading**
- GitHub-flavored Markdown: tables, task lists, strikethrough, footnotes, alerts (`> [!NOTE]`), heading anchors, relative images and YAML front matter
- Syntax-highlighted code blocks with a copy button
- Math with `$inline$`, `$$display$$` or ```` ```math ```` blocks (KaTeX)
- Diagrams from ```` ```mermaid ```` blocks: flowchart, sequence, class, state, ER, Gantt, pie and more
- Rendered or Markdown source view (<kbd>⌘</kbd><kbd>/</kbd>)
- Outline sidebar (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>O</kbd>)
- Word count and reading time
- Live reload when the file changes on disk
- Find in page

**Tabs**
- Drag to reorder, right-click to close others or reveal in Finder
- Reopen closed tabs with <kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd>
- Tabs are restored on relaunch
- Links to other Markdown files open in a new tab, including `guide.md#setup`

**Export**
- PDF (<kbd>⌘</kbd><kbd>E</kbd>), saved to the Desktop by default, with page numbers and clickable links
- HTML (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd>), a single file with styles and images embedded
- Copy as Rich Text (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd>) for Mail, Notes, Pages or Google Docs

**Appearance**
- Light, Dark or System theme
- Sans or serif font, text size and text width

**Other**
- `mdr` command: `mdr README.md` or `cat notes.md | mdr`
- Open files by drag and drop, Finder's Open With, or Open Recent
- Weekly check for new versions on GitHub (can be turned off)

## Install

### Homebrew

```bash
brew install --cask rboundi/tap/mdreader
```

### Download

Download the `.dmg` from [Releases](https://github.com/rboundi/mdreader/releases), open it and drag MDReader to Applications. The app is signed and notarized by Apple.

### Build from source

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). With full Xcode installed, the build also includes Intel.

```bash
git clone https://github.com/rboundi/mdreader.git
cd mdreader
./build.sh --install
```

This installs the app to `/Applications` and links the `mdr` command into `/opt/homebrew/bin` or `/usr/local/bin` if one is writable. The command can also be installed from **MDReader → Install Command Line Tool…**.

### Make it the default Markdown app

Select a `.md` file in Finder, press <kbd>⌘</kbd><kbd>I</kbd>, choose MDReader under **Open with** and click **Change All…**.

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Open | <kbd>⌘</kbd><kbd>O</kbd> |
| Close tab / reopen closed tab | <kbd>⌘</kbd><kbd>W</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd> |
| Next / previous tab | <kbd>⌃</kbd><kbd>Tab</kbd> / <kbd>⌃</kbd><kbd>⇧</kbd><kbd>Tab</kbd> |
| Go to tab 1–8 / last tab | <kbd>⌘</kbd><kbd>1</kbd>…<kbd>⌘</kbd><kbd>8</kbd> / <kbd>⌘</kbd><kbd>9</kbd> |
| Toggle Markdown source | <kbd>⌘</kbd><kbd>/</kbd> |
| Show / hide outline | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>O</kbd> |
| Export as PDF / HTML | <kbd>⌘</kbd><kbd>E</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| Copy as Rich Text | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd> |
| Print | <kbd>⌘</kbd><kbd>P</kbd> |
| Find / next / previous | <kbd>⌘</kbd><kbd>F</kbd> / <kbd>⌘</kbd><kbd>G</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>G</kbd> |
| Reload from disk | <kbd>⌘</kbd><kbd>R</kbd> |
| Zoom in / out / actual size | <kbd>⌘</kbd><kbd>+</kbd> / <kbd>⌘</kbd><kbd>-</kbd> / <kbd>⌘</kbd><kbd>0</kbd> |
| Settings | <kbd>⌘</kbd><kbd>,</kbd> |

## Privacy

MDReader only connects to the internet to load web images a document links to, and to check `api.github.com` for new versions once a week. The update check can be turned off in Settings. There is no analytics or telemetry.

## Project layout

```
Sources/MDReader/
  MDReaderApp.swift       App entry, menus and shortcuts
  AppState.swift          Tabs, opening/closing, exports, persistence
  DocTab.swift            An open file
  FileWatcher.swift       Live reload
  ReaderController.swift  The shared WKWebView: rendering, printing, links
  ContentView.swift       Window layout, toolbar, find bar
  TabBar.swift            Tab strip
  OutlineView.swift       Outline sidebar
  HTMLExport.swift        HTML export and rich-text copy
  UpdateChecker.swift     Release check
  SettingsView.swift      Settings window
Resources/
  web/                    Page template, renderer (app.js), styles, vendored libraries
  mdr                     Command line tool
scripts/                  Icon generator, release script
tests/                    Renderer tests (Node + jsdom)
```

All tabs share one `WKWebView`. Raw HTML in documents is sanitized and the page runs under a Content Security Policy. KaTeX and Mermaid are loaded only for documents that use them.

## Development

```bash
./build.sh                             # builds build/MDReader.app
open build/MDReader.app docs/sample.md
cd tests && npm install && npm test
```

`docs/sample.md` covers every rendering feature. See [CONTRIBUTING.md](CONTRIBUTING.md) for releases.

## License

MIT. See [LICENSE](LICENSE). Bundled libraries are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
