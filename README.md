<p align="center">
  <img src="docs/icon-256.png" width="128" alt="MDReader icon">
</p>

<h1 align="center">MDReader</h1>

<p align="center">A Markdown reader for the Mac. Tables, code, math and diagrams rendered cleanly, with tabs, an outline and PDF export. Free and open source.</p>

<p align="center">
  <img src="docs/screenshot-dark.png" width="760" alt="MDReader showing a document with an outline sidebar, math and a diagram in dark mode">
</p>

## Features

**Reading**
- GitHub-flavored Markdown: tables, task lists, strikethrough, footnotes, alerts (`> [!NOTE]`), heading anchors, relative images and YAML front matter
- Obsidian callouts (`> [!tip] Title`, `> [!faq]-` to start collapsed), `==highlights==` and `:emoji:` shortcodes
- `[TOC]` on its own line inserts a table of contents
- Front matter shows as a small table
- Wiki links: `[[Note]]`, `[[Note|label]]` and `[[Note#Heading]]` open `Note.md` from the same folder
- An image on its own line gets its alt text as a caption
- Links to missing files or headings are struck through
- Syntax-highlighted code blocks with a language label and a copy button, optionally with line numbers or wrapped lines
- Math with `$inline$`, `$$display$$` or ```` ```math ```` blocks (KaTeX)
- Diagrams from ```` ```mermaid ```` blocks: flowchart, sequence, class, state, ER, Gantt, pie and more
- Rendered or Markdown source view (<kbd>⌘</kbd><kbd>/</kbd>), staying at the same section, with optional line numbers
- Focus mode hides the tabs, toolbar and sidebar (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd>, <kbd>Esc</kbd> to leave)
- Footnotes show on hover
- Sidebar with the document outline or the folder's Markdown files and subfolders, with a filter and sorting by name or date. Drag its edge to resize it
- Collapsible sections, remembered per file. **View → Collapse All Sections**, or <kbd>⌥</kbd>-click an arrow to fold every section at that level
- Click a table header to sort by that column
- Right-click a diagram to copy it or save it as PNG or SVG
- Click a task's checkbox to tick it in the file
- <kbd>⌘</kbd>-click a link to open it in a background tab
- Hover a link to see where it goes; links to other notes show a preview of the linked section
- Right-click a table to copy it for Numbers or Excel, or as CSV
- Right-click a formula to copy its LaTeX
- Right-click an image to open it in Preview or show it in Finder
- Hover a heading and click **#** to copy a link to it
- Image zoom and a reading progress bar
- Optional heading numbers (1, 1.1, 1.2) in the document and the outline
- Keyboard reading: <kbd>j</kbd> / <kbd>k</kbd> to scroll, <kbd>n</kbd> / <kbd>p</kbd> for the next or previous heading, <kbd>g</kbd> / <kbd>G</kbd> for the top or bottom
- Back and Forward after following links, also with a two-finger swipe or the mouse side buttons
- Jump to Heading (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>J</kbd>)
- Reopens each file where you left off
- Word count, time left, tasks done and last modified date in the title bar
- Select text to see how many words it has
- The front matter `title:` is used as the tab and window title
- Live reload when the file changes on disk, scrolling to the part that changed
- Find in page, and search across open tabs or the folder (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>F</kbd>)

**Tabs**
- Drag to reorder, or drag a tab to Finder or another app to use the file. Middle-click to close
- Right-click to rename, duplicate, close others or reveal in Finder
- A dot on a tab whose file changed while you were looking at another one
- Quick Open (<kbd>⌘</kbd><kbd>P</kbd>) for open tabs, recent files and files in the same folder
- Reopen closed tabs with <kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd> or from **File → Recently Closed**
- Tabs are restored on relaunch
- Links to other Markdown files open in a new tab, including `guide.md#setup`
- Right-click a heading to copy a link to it

**Export**
- PDF (<kbd>⌘</kbd><kbd>E</kbd>), saved to the Desktop by default, with page numbers and clickable links, in A4 or US Letter
- HTML (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd>), a single file with styles and images embedded
- Word (.docx) and RTF, as text: images and diagrams are left out
- Copy as Rich Text (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd>) for Mail, Notes, Pages or Google Docs, or **Edit → Copy as HTML** for the HTML itself

**Appearance**
- Light, Sepia, Dark or System theme; images are dimmed slightly in dark mode
- Sans or serif font, text size, text width and line spacing, justified text, smart quotes and dashes
- Your own styles in `~/Library/Application Support/MDReader/custom.css` (**Settings → Appearance → Custom CSS → Edit…**)

**Editing**
- **Edit** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>O</kbd>) switches to a text editor with the rendered page beside it; <kbd>⌘</kbd><kbd>S</kbd> saves
- <kbd>⌘</kbd><kbd>B</kbd>, <kbd>⌘</kbd><kbd>I</kbd> and <kbd>⌘</kbd><kbd>K</kbd> for bold, italic and links; lists continue when you press Return
- <kbd>Tab</kbd> and <kbd>⇧</kbd><kbd>Tab</kbd> indent and outdent list items; pasting a web address over selected text makes a link
- **New Document** (<kbd>⌘</kbd><kbd>N</kbd>)
- To edit in another app instead, choose it in **Settings → Editing → Edit with**. Changes show as soon as you save

**Other**
- Share button for Mail, Messages and AirDrop
- Open a folder to read its README with the other files in the sidebar
- `mdr` command: `mdr README.md`, `mdr docs` or `cat notes.md | mdr`
- Open files by drag and drop, Finder's Open With, Open Recent or the Dock menu
- Open copied Markdown text in a new tab (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>V</kbd>)
- Weekly check for new versions on GitHub (can be turned off)

## Install

### Homebrew

```bash
brew install --cask rboundi/tap/mdreader
```

### Download

Download [MDReader.dmg](https://github.com/rboundi/mdreader/releases/latest/download/MDReader.dmg), open it and drag MDReader to Applications. The app is signed and notarized by Apple.

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
| New document / Open | <kbd>⌘</kbd><kbd>N</kbd> / <kbd>⌘</kbd><kbd>O</kbd> |
| Quick Open | <kbd>⌘</kbd><kbd>P</kbd> |
| Open Clipboard | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>V</kbd> |
| Back / Forward | <kbd>⌘</kbd><kbd>[</kbd> / <kbd>⌘</kbd><kbd>]</kbd> |
| Jump to Heading | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>J</kbd> |
| Edit / stop editing | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>O</kbd> |
| Save | <kbd>⌘</kbd><kbd>S</kbd> |
| Bold / italic / link (editing) | <kbd>⌘</kbd><kbd>B</kbd> / <kbd>⌘</kbd><kbd>I</kbd> / <kbd>⌘</kbd><kbd>K</kbd> |
| Focus mode | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd> |
| Close tab / reopen closed tab | <kbd>⌘</kbd><kbd>W</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd> |
| Next / previous tab | <kbd>⌃</kbd><kbd>Tab</kbd> / <kbd>⌃</kbd><kbd>⇧</kbd><kbd>Tab</kbd> |
| Go to tab 1–8 / last tab | <kbd>⌘</kbd><kbd>1</kbd>…<kbd>⌘</kbd><kbd>8</kbd> / <kbd>⌘</kbd><kbd>9</kbd> |
| Toggle Markdown source | <kbd>⌘</kbd><kbd>/</kbd> |
| Outline / Files sidebar | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>O</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| Export as PDF / HTML | <kbd>⌘</kbd><kbd>E</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| Copy as Rich Text | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd> |
| Print | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd> |
| Scroll down / up | <kbd>j</kbd> / <kbd>k</kbd> |
| Next / previous heading | <kbd>n</kbd> / <kbd>p</kbd> |
| Top / bottom | <kbd>g</kbd> / <kbd>G</kbd> |
| Search in files | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>F</kbd> |
| Find / next / previous | <kbd>⌘</kbd><kbd>F</kbd> / <kbd>⌘</kbd><kbd>G</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>G</kbd> |
| Reload from disk | <kbd>⌘</kbd><kbd>R</kbd> |
| Zoom in / out / actual size | <kbd>⌘</kbd><kbd>+</kbd> / <kbd>⌘</kbd><kbd>-</kbd> / <kbd>⌘</kbd><kbd>0</kbd> |
| Settings | <kbd>⌘</kbd><kbd>,</kbd> |

## Privacy

MDReader only connects to the internet to load web images a document links to, and to check `github.com` for new versions once a week. The update check can be turned off in Settings. There is no analytics or telemetry.

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
  SidebarView.swift       Sidebar and Files list
  SearchView.swift        Search across tabs or the folder
  OutlineView.swift       Outline
  PaletteView.swift       Quick Open and Jump to Heading
  EditorView.swift        The text editor
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
