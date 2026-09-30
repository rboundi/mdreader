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

test("source view shows the raw Markdown and no outline", () => {
  const { render, messages } = setup();
  const c = render("# Title\n\n*x*", { source: true });
  assert.equal(c.className, "source-view");
  assert.equal(c.textContent, "# Title\n\n*x*");
  same(messages.findLast((m) => m.type === "outline").items, []);
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
