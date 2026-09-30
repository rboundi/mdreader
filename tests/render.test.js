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
  assert.doesNotMatch(out.html, /copy-btn|class="anchor"/);
  assert.match(out.html, /href="file:\/\/\/tmp\/docs\/other\.md"/);
  same(out.images, ["file:///tmp/docs/pic.png"]);
  assert.doesNotMatch(out.text, /Copy/);
});
