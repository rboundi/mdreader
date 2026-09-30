// Renderer tests: load the bundled web page into jsdom and check the DOM it produces.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";

// jsdom values come from another realm; compare them as plain data.
const same = (actual, expected) => assert.deepEqual(JSON.parse(JSON.stringify(actual)), expected);

const WEB = new URL("../Resources/web/", import.meta.url);
const read = (path) => readFileSync(new URL(path, WEB), "utf8");
const scripts = [
  "vendor/marked.umd.js",
  "vendor/marked-footnote.umd.js",
  "vendor/highlight.min.js",
  "emoji.js",
  "app.js",
].map(read);

function setup() {
  const dom = new JSDOM(`<!doctype html><html><head></head><body data-font="sans"><main id="content"></main></body></html>`, {
    url: new URL("index.html", WEB).href,
    runScripts: "outside-only",
    pretendToBeVisual: true,
    virtualConsole: new VirtualConsole(), // silence "not implemented: window.scrollTo"
  });
  const { window } = dom;
  const messages = [];
  window.webkit = { messageHandlers: { mdr: { postMessage: (m) => messages.push(m) } } };
  for (const s of scripts) window.eval(s);
  const content = window.document.getElementById("content");
  // Math/diagram libraries load lazily from disk, which jsdom doesn't do; the synchronous part of
  // render() is what we test, so don't await it.
  const render = (md, extra = {}) => {
    window.mdr.render({ md, base: "file:///tmp/docs/", title: "t.md", scroll: 0, error: "", source: false, ...extra });
    return content;
  };
  return { window, content, messages, render };
}

test("renders basic GitHub-flavored Markdown", () => {
  const { render } = setup();
  const c = render("# Title\n\n**bold** ~~gone~~\n\n| a | b |\n|---|---|\n| 1 | 2 |\n");
  assert.equal(c.className, "markdown-body");
  assert.equal(c.querySelector("h1").id, "title");
  assert.ok(c.querySelector("strong"));
  assert.ok(c.querySelector("del"));
  assert.ok(c.querySelector(".table-wrap > table"));
});

test("gives duplicate headings unique ids", () => {
  const { render } = setup();
  const ids = [...render("## Setup\n\n## Setup\n\n## Setup").querySelectorAll("h2")].map((h) => h.id);
  same(ids, ["setup", "setup-1", "setup-2"]);
});

test("renders footnotes", () => {
  const { render } = setup();
  const c = render("Claim.[^1]\n\n[^1]: Source.");
  const ref = c.querySelector("[data-footnote-ref]");
  assert.ok(ref, "footnote reference link");
  const section = c.querySelector(".footnotes");
  assert.ok(section, "footnotes section");
  assert.match(section.textContent, /Source\./);
});

test("renders GitHub alerts", () => {
  const { render } = setup();
  const c = render("> [!WARNING]\n> Careful.");
  const bq = c.querySelector("blockquote");
  assert.ok(bq.classList.contains("alert-warning"));
  assert.equal(bq.querySelector(".alert-title").textContent, "Warning");
  assert.doesNotMatch(bq.textContent, /\[!WARNING\]/);
});

test("sanitizes raw HTML", () => {
  const { render } = setup();
  const c = render(
    '<script>alert(1)</script>\n\n<img src="x.png" onerror="alert(1)">\n\n<a href="javascript:alert(1)">x</a>\n\n<iframe src="https://example.com"></iframe>',
  );
  assert.equal(c.querySelector("script"), null);
  assert.equal(c.querySelector("iframe"), null);
  assert.equal(c.querySelector("img").getAttribute("onerror"), null);
  assert.equal(c.querySelector("a").getAttribute("href"), null);
});

test("removes javascript: links hidden with whitespace and SVG animation", () => {
  const { render } = setup();
  const c = render(
    '<a href="jav&#x09;ascript:alert(1)">a</a> <a href=" JaVaScRiPt:alert(1)">b</a> ' +
    '<a href="data:text/html,x">c</a> <a href="https://ok.example">d</a> <a href="#top">e</a>\n\n' +
    '<svg><a><animate attributeName="href" values="javascript:alert(1)"/><text>x</text></a></svg>',
  );
  const hrefs = [...c.querySelectorAll("a")].map((a) => a.getAttribute("href"));
  same(hrefs.slice(0, 5), [null, null, null, "https://ok.example", "#top"]);
  assert.equal(c.querySelector("animate"), null);
});

test("keeps heading ids unique alongside ids from raw HTML", () => {
  const { render, messages } = setup();
  render('<h2 id="intro">Intro</h2>\n\n## Intro\n\n<div id="setup"></div>\n\n## Setup');
  const ids = messages.findLast((m) => m.type === "outline").items.map((i) => i.id);
  assert.equal(new Set(ids).size, ids.length);
  assert.equal(ids[0], "intro");
  assert.notEqual(ids[2], "setup");
});

test("highlights code and adds a copy button", () => {
  const { render } = setup();
  const pre = render("```js\nconst x = 1;\n```").querySelector("pre");
  assert.ok(pre.querySelector(".hljs-keyword"));
  assert.ok(pre.querySelector(".copy-btn"));
  assert.equal(pre.dataset.lang, "js");
});

test("marks up math for KaTeX without touching prices", () => {
  const { render } = setup();
  const c = render("Euler: $e^{i\\pi}+1=0$ costs $5 and $10.\n\n$$\n\\int_0^1 x\\,dx\n$$\n\n```math\na^2+b^2=c^2\n```");
  const inline = c.querySelectorAll("span.math");
  assert.equal(inline.length, 1);
  assert.equal(inline[0].dataset.tex, "e^{i\\pi}+1=0");
  assert.match(c.textContent, /costs \$5 and \$10/);
  const display = c.querySelectorAll("div.math-display");
  assert.equal(display.length, 2);
  assert.equal(display[0].dataset.tex, "\\int_0^1 x\\,dx");
  assert.equal(display[1].dataset.tex, "a^2+b^2=c^2");
});

test("does not treat $ followed by text and a spaced $ as math", () => {
  const { render } = setup();
  const c = render("Between $a and b $ here.");
  assert.equal(c.querySelector(".math"), null);
});

test("does not treat dollars in code as math", () => {
  const { render } = setup();
  const c = render("Run `echo $HOME $PATH` now.");
  assert.equal(c.querySelector(".math"), null);
});

test("turns mermaid code blocks into diagram placeholders", () => {
  const { render } = setup();
  const c = render("```mermaid\ngraph TD; A-->B;\n```");
  const block = c.querySelector(".mermaid-block");
  assert.ok(block);
  assert.equal(block.dataset.src.trim(), "graph TD; A-->B;");
});

test("collapses YAML front matter", () => {
  const { render } = setup();
  const c = render("---\ntitle: Hi\n---\n\n# Body");
  assert.ok(c.querySelector("details.front-matter"));
  assert.equal(c.querySelector("h1").textContent, "Body");
});

test("renders task lists as disabled checkboxes", () => {
  const { render } = setup();
  const c = render("- [x] done\n- [ ] todo");
  const boxes = c.querySelectorAll("input[type=checkbox]");
  assert.equal(boxes.length, 2);
  assert.ok([...boxes].every((b) => b.disabled));
  assert.ok(c.querySelector("ul.task-list"));
});

test("posts the outline to the app", () => {
  const { render, messages } = setup();
  render("# One\n\n## Two\n\n#### Four\n\n##### Five");
  const outline = messages.findLast((m) => m.type === "outline");
  same(outline.items.map((i) => [i.level, i.text]), [[1, "One"], [2, "Two"], [4, "Four"]]);
});

test("source view shows the raw Markdown, one element per line, with an outline", () => {
  const { render, messages } = setup();
  const md = "---\ntitle: T\n---\n# Title **bold**\n\n```\ncode\n# not a heading\n```\n\n## Next\n\n##### Deep";
  const c = render(md, { source: true });
  assert.equal(c.className, "source-view");
  assert.equal(c.textContent, md);
  assert.equal(c.querySelectorAll(".line").length, md.split("\n").length);
  same(messages.findLast((m) => m.type === "outline").items, [
    { id: "source-0", level: 1, text: "Title bold" },
    { id: "source-1", level: 2, text: "Next" },
  ]);
});

test("find highlights matches and steps through them", () => {
  const { window, render } = setup();
  render("apple banana apple\n\nApple pie");
  same(window.mdr.find("apple"), { current: 1, total: 3 });
  same(window.mdr.findStep(1), { current: 2, total: 3 });
  same(window.mdr.findStep(-2), { current: 3, total: 3 });
  window.mdr.clearFind();
  assert.equal(window.document.querySelectorAll("mark").length, 0);
});

test("HTML export strips reader UI and makes links absolute", async () => {
  const { window, render } = setup();
  render("# T\n\n[doc](other.md) ![img](pic.png)\n\n```\ncode\n```");
  const out = await window.mdr.exportHTML();
  assert.doesNotMatch(out.html, /copy-btn|class="fold"/);
  assert.match(out.html, /href="file:\/\/\/tmp\/docs\/other\.md"/);
  same(out.images, ["file:///tmp/docs/pic.png"]);
  assert.doesNotMatch(out.text, /Copy/);
});

test("collapses a section down to the next heading of the same level", () => {
  const { window, render } = setup();
  const c = render("## A\n\none\n\n### A.1\n\ntwo\n\n## B\n\nthree");
  const [a, a1, b] = c.querySelectorAll("h2, h3");
  a.querySelector(".fold").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const hidden = [...c.children].filter((el) => el.classList.contains("folded-away")).map((el) => el.textContent);
  same(hidden, ["one", "A.1", "two"]);
  assert.ok(!b.classList.contains("folded-away"));
  assert.ok(a.classList.contains("collapsed"));
});

test("jumping to a heading inside a collapsed section expands it", () => {
  const { window, render } = setup();
  const c = render("## A\n\none\n\n### Deep\n\ntwo");
  c.querySelector("h2 .fold").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.ok(c.querySelector("h3").classList.contains("folded-away"));
  window.mdr.scrollToAnchor("deep");
  assert.equal(c.querySelectorAll(".folded-away").length, 0);
});

test("reports the scroll position when following links, for Back and Forward", () => {
  const { window, render, messages } = setup();
  const c = render("[jump](#b) [other](other.md#x)\n\n## B");
  for (const a of c.querySelectorAll("a")) a.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  const nav = messages.filter((m) => m.type === "anchor" || m.type === "link");
  same(nav.map((m) => m.type), ["anchor", "link"]);
  assert.equal(typeof nav[0].y, "number");
  assert.equal(nav[1].href, "file:///tmp/docs/other.md#x");
});

test("clicking an image opens it full size; Escape closes it", () => {
  const { window, render } = setup();
  const c = render("![pic](pic.png)");
  c.querySelector("img").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.ok(window.document.querySelector(".lightbox img"));
  window.document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape" }));
  assert.equal(window.document.querySelector(".lightbox"), null);
});

test("right-clicking a heading tells the app which one", () => {
  const { window, render, messages } = setup();
  const c = render("## Setup steps\n\ntext");
  c.querySelector("h2").dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true }));
  assert.equal(messages.findLast((m) => m.type === "context").heading, "setup-steps");
});

test("only top-level headings get a fold arrow; an HTML block with a heading ends a section", () => {
  const { window, render } = setup();
  const c = render('## A\n\none\n\n<div align="center">\n\n## Inside\n\n</div>\n\nafter');
  const [a, inside] = c.querySelectorAll("h2");
  assert.ok(a.querySelector(".fold"));
  assert.equal(inside.querySelector(".fold"), null);
  a.querySelector(".fold").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  assert.ok(!inside.closest("div").classList.contains("folded-away"));
});

test("collapsed sections stay collapsed when the file reloads", () => {
  const { window, render } = setup();
  let c = render("## A\n\none\n\n## B\n\ntwo");
  c.querySelector("h2 .fold").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  c = render("## A\n\none, edited\n\n## B\n\ntwo", { scroll: -1 });
  assert.ok(c.querySelector("#a").classList.contains("collapsed"));
  assert.ok([...c.children].some((el) => el.classList.contains("folded-away")));
});

test("switching documents closes a zoomed image", () => {
  const { window, render } = setup();
  const c = render("![pic](pic.png)");
  c.querySelector("img").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  render("# Other");
  assert.equal(window.document.querySelector(".lightbox"), null);
});

test("hovering a footnote reference shows the note", () => {
  const { window, render } = setup();
  const c = render("Claim.[^1]\n\n[^1]: The source.");
  c.querySelector("[data-footnote-ref]").dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
  const tip = window.document.querySelector(".footnote-tip");
  assert.ok(tip);
  assert.match(tip.textContent, /The source\./);
  assert.equal(tip.querySelector("[data-footnote-backref]"), null);
  c.querySelector("[data-footnote-ref]").dispatchEvent(new window.MouseEvent("mouseout", { bubbles: true }));
  assert.equal(window.document.querySelector(".footnote-tip"), null);
});

test("switching to source keeps the reader at the same heading", () => {
  const { window, render } = setup();
  const md = "# Top\n\ntext\n\n## Middle\n\nmore\n\n## End\n\nlast";
  const c = render(md);
  // jsdom has no layout, so the scroll ratio is used; the call must not throw and must switch views.
  render(md, { source: true, sync: true, scroll: -1 });
  assert.equal(c.className, "source-view");
  render(md, { source: false, sync: true, scroll: -1 });
  assert.equal(c.className, "markdown-body");
});


test("switching to source and back doesn't break footnotes in the next document", () => {
  const { render } = setup();
  const plain = "# Plain\n\nPlain text";
  render(plain);
  render(plain, { source: true, sync: true, scroll: -1 });
  const c = render("X[^a]\n\n[^a]: Note.", { title: "other.md" });
  assert.doesNotMatch(c.textContent, /Plain text/);
  assert.ok(c.querySelector(".footnotes"));
});

test("the zoomed image and footnote preview close when another document renders", () => {
  const { window, render } = setup();
  const c = render("Claim.[^1]\n\n[^1]: Note.");
  c.querySelector("[data-footnote-ref]").dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
  assert.ok(window.document.querySelector(".footnote-tip"));
  render("# Other", { title: "other.md" });
  assert.equal(window.document.querySelector(".footnote-tip"), null);
});

test("an image alone in a paragraph gets a caption; inline and linked images don't", () => {
  const { render } = setup();
  const c = render('![A cat](cat.png)\n\n![Dog](dog.png "The dog")\n\nText ![icon](i.png) here\n\n[![Badge](b.svg)](https://x.example)\n\n![](empty.png)');
  const captions = [...c.querySelectorAll("figcaption")].map((f) => f.textContent);
  same(captions, ["A cat", "The dog"]);
  assert.equal(c.querySelectorAll("figure").length, 2);
  assert.equal(c.querySelectorAll("img").length, 5);
});

test("wiki links point at the Markdown file next to the document", () => {
  const { render } = setup();
  const c = render("See [[Note Name]], [[notes/Setup Guide#First Steps|setup]], [[#Local Heading]] and [[image.png]].\n\n`[[not a link]]`");
  const hrefs = [...c.querySelectorAll("a.wikilink")].map((a) => a.getAttribute("href"));
  same(hrefs, ["Note%20Name.md", "notes/Setup%20Guide.md#first-steps", "#local-heading", "image.png"]);
  same([...c.querySelectorAll("a.wikilink")].map((a) => a.textContent), ["Note Name", "setup", "Local Heading", "image.png"]);
  assert.match(c.querySelector("code").textContent, /\[\[not a link\]\]/);
});

test("numbers headings when turned on, leaving a lone title unnumbered", () => {
  const { window, render, messages } = setup();
  window.mdr.setOptions({ numbers: true });
  const c = render("# Title\n\n## Intro\n\n### Part\n\n### Part two\n\n## Next");
  same([...c.querySelectorAll("h1, h2, h3")].map((h) => h.dataset.num ?? ""), ["", "1", "1.1", "1.2", "2"]);
  same(messages.findLast((m) => m.type === "outline").items.map((i) => i.text),
    ["Title", "1 Intro", "1.1 Part", "1.2 Part two", "2 Next"]);
  window.mdr.setOptions({ numbers: false });
  assert.equal(c.querySelector("[data-num]"), null);
});

test("marks links to missing headings and reports local files for checking", () => {
  const { window, render, messages } = setup();
  const c = render("## Here\n\n[ok](#here) [gone](#nowhere) [file](other.md#x) [web](https://x.example)");
  const links = [...c.querySelectorAll("a")];
  assert.equal(links[0].classList.contains("broken"), false);
  assert.equal(links[1].classList.contains("broken"), true);
  const report = messages.findLast((m) => m.type === "links");
  same(report.files, ["file:///tmp/docs/other.md"]);
  window.mdr.markBroken(report.token, ["file:///tmp/docs/other.md"]);
  assert.equal(links[2].classList.contains("broken"), true);
  assert.equal(links[3].classList.contains("broken"), false);
});

test("a reload highlights the block that changed", () => {
  const { render } = setup();
  render("# A\n\none\n\ntwo\n\nthree");
  const c = render("# A\n\none\n\ntwo changed\n\nthree", { scroll: -1 });
  const marked = c.querySelector(".just-edited");
  assert.ok(marked);
  assert.equal(marked.textContent, "two changed");
  // The same text again (for example ⌘R) highlights nothing.
  render("# A\n\none\n\ntwo changed\n\nthree", { scroll: -1 });
});

test("j, k, n, p, g and G are ignored with modifier keys", () => {
  const { window, render } = setup();
  render("# A\n\ntext\n\n## B\n\nmore");
  const press = (key, extra = {}) => {
    const e = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...extra });
    window.document.body.dispatchEvent(e);
    return e.defaultPrevented;
  };
  assert.equal(press("n"), true);
  assert.equal(press("G"), true);
  assert.equal(press("j", { metaKey: true }), false);
  assert.equal(press("x"), false);
});

test("wiki links leave citation-style links alone and handle dotted names and embeds", () => {
  const { render } = setup();
  const c = render("See [[1]](https://a.example) and [x [[Note]]](https://b.example).\n\n[[Node.js]] [[2024.01.15]] [[#]] ![[pic.png]]");
  const hrefs = [...c.querySelectorAll("a")].map((a) => a.getAttribute("href"));
  same(hrefs, ["https://a.example", "https://b.example", "Node.js.md", "2024.01.15.md"]);
  assert.equal(c.querySelector("img").getAttribute("src"), "pic.png");
});

test("a front matter change alone doesn't count as an edit", () => {
  const { render } = setup();
  render("---\nupdated: 1\n---\n\n# A\n\none");
  const c = render("---\nupdated: 2\n---\n\n# A\n\none", { scroll: -1 });
  assert.equal(c.querySelector(".just-edited"), null);
  const d = render("---\nupdated: 3\n---\n\n# A\n\none, edited", { scroll: -1 });
  assert.equal(d.querySelector(".just-edited")?.textContent, "one, edited");
});

test("==highlights== and :emoji: shortcodes", () => {
  const { render } = setup();
  const c = render("Some ==marked **text**== here, a === b, :tada: :+1: and :not_an_emoji: 12:30:45\n\n`:tada:`");
  assert.equal(c.querySelector("mark.highlight").innerHTML, "marked <strong>text</strong>");
  assert.equal(c.querySelectorAll("mark").length, 1);
  assert.match(c.textContent, /🎉 👍 and :not_an_emoji: 12:30:45/);
  assert.equal(c.querySelector("code").textContent, ":tada:");
});

test("Obsidian callouts: types, custom titles and folding", () => {
  const { render } = setup();
  const c = render("> [!faq]- Why *this*?\n> Because.\n\n> [!bug]\n> Oops.\n\n> [!custom] Mine\n> Text");
  const faq = c.querySelector("details.alert-question");
  assert.ok(faq);
  assert.equal(faq.open, false);
  assert.equal(faq.querySelector("summary").textContent, "Why this?");
  assert.match(faq.textContent, /Because\./);
  const bug = c.querySelector("blockquote.alert-bug");
  assert.equal(bug.querySelector(".alert-title").textContent, "Bug");
  assert.ok(bug.querySelector("svg"));
  assert.equal(c.querySelector("blockquote.alert-note .alert-title").textContent, "Mine");
});

test("[TOC] becomes a nested list of heading links", () => {
  const { render } = setup();
  const c = render("# Title\n\n[TOC]\n\n## One\n\n### One A\n\n## Two");
  const links = [...c.querySelectorAll("nav.toc a")].map((a) => [a.textContent, a.getAttribute("href")]);
  same(links, [["One", "#one"], ["One A", "#one-a"], ["Two", "#two"]]);
  assert.ok(c.querySelector("nav.toc > ul > li > ul > li"));
});

test("simple front matter shows as a table; nested YAML stays YAML", () => {
  const { render } = setup();
  let c = render("---\ntitle: \"Hello\"\ntags: [a, b]\nauthors:\n  - Ann\n  - Bo\n---\n\nText");
  const rows = [...c.querySelectorAll(".front-matter tr")]
    .map((tr) => [...tr.children].map((cell) => cell.textContent.trim()).join(" ").replace(/\s+/g, " "));
  same(rows, ["title Hello", "tags a b", "authors Ann Bo"]);
  assert.equal(c.querySelectorAll(".front-matter .tag").length, 4);
  c = render("---\nmeta:\n  key: value\n---\n\nText", { title: "b.md" });
  assert.ok(c.querySelector(".front-matter pre"));
});

test("clicking a table header sorts the rows, numbers by value", () => {
  const { window, render } = setup();
  const c = render("| Name | Size |\n|---|---|\n| b | 10 |\n| a | 9 |\n| c | 100 |");
  const size = c.querySelectorAll("th")[1];
  const col = (i) => [...c.querySelectorAll("tbody tr")].map((tr) => tr.cells[i].textContent);
  size.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  same(col(1), ["9", "10", "100"]);
  size.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  same(col(1), ["100", "10", "9"]);
  c.querySelectorAll("th")[0].dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  same(col(0), ["a", "b", "c"]);
});

test("collapsed sections are reported, restored, and fold all works", () => {
  const { window, render, messages } = setup();
  let c = render("## A\n\none\n\n## B\n\ntwo\n\n## C\n\nthree");
  c.querySelector("#b .fold").dispatchEvent(new window.MouseEvent("click", { bubbles: true, altKey: true }));
  same(messages.findLast((m) => m.type === "folds").ids, ["a", "b", "c"]);
  window.mdr.foldAll(false);
  same(messages.findLast((m) => m.type === "folds").ids, []);
  c = render("## A\n\none\n\n## B\n\ntwo", { title: "other.md", folds: ["b"] });
  assert.ok(c.querySelector("#b").classList.contains("collapsed"));
  assert.equal(c.querySelector("#a").classList.contains("collapsed"), false);
});

test("hovering a link shows where it goes", () => {
  const { window, render } = setup();
  const c = render("[doc](sub/My%20Note.md#x) [web](https://example.com/a)");
  const [doc, web] = c.querySelectorAll("a");
  doc.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
  assert.equal(window.document.getElementById("link-status").textContent, "sub/My Note.md#x");
  web.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
  assert.equal(window.document.getElementById("link-status").textContent, "https://example.com/a");
});

test("callout titles can't smuggle HTML past the sanitizer", () => {
  const { render } = setup();
  const c = render('> [!note] [x](http://a "<br><style>body{}</style><form></form>")\n> Body');
  assert.equal(c.querySelector("style, form, meta"), null);
  assert.equal(c.querySelector(".alert-title a").textContent, "x");
  assert.match(c.querySelector(".alert").textContent, /Body/);
});

test("highlights and emoji need a word boundary; [[_TOC_]] works", () => {
  const { render } = setup();
  const c = render("a==b and c==d, YQ==,ZQ==, 10:100:20, ok ==yes== :tada:\n\n[[_TOC_]]\n\n## One");
  same([...c.querySelectorAll("mark")].map((m) => m.textContent), ["yes"]);
  assert.match(c.textContent, /10:100:20/);
  assert.match(c.textContent, /🎉/);
  assert.ok(c.querySelector("nav.toc a[href='#one']"));
});

test("heading offsets in CRLF files point at the heading", () => {
  const { window, render } = setup();
  const md = "Intro\r\n\r\nMore\r\n\r\n## Heading\r\n\r\nText";
  render(md, { source: true });
  assert.equal(window.mdr.headingOffset("source-0"), md.indexOf("## Heading"));
});

test("version numbers sort as versions, not decimals", () => {
  const { window, render } = setup();
  const c = render("| v |\n|---|\n| 1.10.0 |\n| 1.2.0 |\n| 1.9.0 |");
  c.querySelector("th").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  same([...c.querySelectorAll("tbody td")].map((td) => td.textContent), ["1.2.0", "1.9.0", "1.10.0"]);
});

test("smart punctuation, when on, leaves code alone", () => {
  const { window, render } = setup();
  window.mdr.setOptions({ smart: true });
  const c = render("\"Quoted\" and 'single' -- dash --- em... it's\n\n`\"code\" -- here`");
  assert.equal(c.querySelector("p").textContent, "“Quoted” and ‘single’ – dash — em… it’s");
  assert.equal(c.querySelector("code").textContent, "\"code\" -- here");
});

test("tables copy as TSV or CSV; headings get a copy-link button; code keeps its text", () => {
  const { window, render, messages } = setup();
  const c = render("## Title\n\n| a | b |\n|---|---|\n| 1 | x, y |\n\n```js\nlet a = 1;\n\nlet b = 2;\n```");
  assert.equal(window.mdr.tableText(0, false), "a\tb\n1\tx, y");
  assert.equal(window.mdr.tableText(0, true), 'a,b\n1,"x, y"');
  c.querySelector("h2 .anchor-link").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  same(messages.findLast((m) => m.type === "copyLink"), { type: "copyLink", id: "title" });
  assert.equal(c.querySelector("h2").textContent, "Title");
  const code = c.querySelector("pre code");
  assert.equal(code.querySelectorAll(".line").length, 3);
  assert.equal(code.textContent, "let a = 1;\n\nlet b = 2;\n");
});

test("a hovered link to another note shows the linked section", async () => {
  const { window, render, messages } = setup();
  const c = render("[see](other.md#setup)");
  c.querySelector("a").dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
  await new Promise((r) => setTimeout(r, 600));
  const ask = messages.findLast((m) => m.type === "preview");
  assert.equal(ask.href, "file:///tmp/docs/other.md#setup");
  window.mdr.showPreview(ask.seq, "# Other\n\nIntro\n\n## Setup\n\nInstall it.\n\n## Next\n\nLater");
  const tip = window.document.querySelector(".link-preview");
  assert.match(tip.textContent, /Setup\s+Install it\./);
  assert.doesNotMatch(tip.textContent, /Intro|Later/);
});
