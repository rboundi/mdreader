# Third-party notices

MDReader bundles the following libraries, unmodified, in `Resources/web/vendor/`. Their license headers are preserved in each file.

| Library | Version | License | Used for | Loaded |
|---|---|---|---|---|
| [marked](https://github.com/markedjs/marked) | 18.0.14 | MIT | Markdown parsing | always |
| [marked-footnote](https://github.com/bent10/marked-extensions) | 1.4.0 | MIT | Footnotes | always |
| [highlight.js](https://github.com/highlightjs/highlight.js) | 11.12.0 | BSD-3-Clause | Code highlighting | always |
| [KaTeX](https://github.com/KaTeX/KaTeX) | 0.18.9 | MIT | Math (`$…$`, `$$…$$`) | only when a document contains math |
| [Mermaid](https://github.com/mermaid-js/mermaid) (`@mermaid-js/tiny`) | 12.0.0 | MIT | Diagrams | only when a document contains a `mermaid` block |

Only KaTeX's `.woff2` fonts are included. The tiny Mermaid build doesn't support mindmap or architecture diagrams, or math inside diagrams.
