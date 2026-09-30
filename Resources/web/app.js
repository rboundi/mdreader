(() => {
  "use strict";

  const post = (msg) => window.webkit?.messageHandlers?.mdr?.postMessage(msg);
  // Resolve bundled files against app.js itself — <base> is repointed at each document's folder.
  const ROOT = (document.currentScript?.src || location.href).replace(/[^/]*$/, "");
  let content = document.getElementById("content");

  const ALERTS = {
    NOTE: "Note", TIP: "Tip", IMPORTANT: "Important", WARNING: "Warning", CAUTION: "Caution",
  };

  // ---------- helpers ----------

  const escapeHTML = (s) =>
    s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  const loaded = new Map();
  function loadScript(path) {
    if (!loaded.has(path)) {
      loaded.set(path, new Promise((resolve, reject) => {
        const s = document.createElement("script");
        s.src = ROOT + path;
        s.onload = resolve;
        s.onerror = () => { loaded.delete(path); reject(new Error("Could not load " + path)); };
        document.head.append(s);
      }));
    }
    return loaded.get(path);
  }

  function loadStyle(path) {
    if (!document.querySelector(`link[data-path="${path}"]`)) {
      const l = document.createElement("link");
      l.rel = "stylesheet";
      l.href = ROOT + path;
      l.dataset.path = path;
      document.head.append(l);
    }
  }

  const prefersDark = () => !!window.matchMedia?.("(prefers-color-scheme: dark)").matches;

  function setBase(href) {
    let base = document.querySelector("base");
    if (!base) {
      base = document.createElement("base");
      document.head.prepend(base);
    }
    base.href = href;
  }

  function slugify(text, used) {
    const slug = text.trim().toLowerCase()
      .replace(/[^\p{L}\p{N}\s_-]/gu, "")
      .replace(/\s/g, "-") || "section";
    const n = used.get(slug) || 0;
    used.set(slug, n + 1);
    return n ? `${slug}-${n}` : slug;
  }

  function splitFrontMatter(md) {
    const m = md.match(/^---[ \t]*\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/);
    return m ? [m[1], md.slice(m[0].length)] : [null, md];
  }

  function scrollToAnchor(id, smooth) {
    if (!id) return false;
    let target = document.getElementById(id) || document.getElementsByName(id)[0];
    if (!target) {
      try { target = document.getElementById(decodeURIComponent(id)); } catch (_) {}
    }
    target?.scrollIntoView?.({ behavior: smooth ? "smooth" : "auto", block: "start" });
    return !!target;
  }

  // ---------- markdown extensions ----------

  // $inline$ and $$display$$ math. Rendered lazily by KaTeX only when present.
  const math = {
    extensions: [
      {
        name: "mathBlock",
        level: "block",
        start: (src) => src.match(/^\$\$/m)?.index,
        tokenizer(src) {
          const m = /^\$\$([\s\S]+?)\$\$[ \t]*(?:\n|$)/.exec(src);
          if (m) return { type: "mathBlock", raw: m[0], text: m[1].trim() };
        },
        renderer: (t) => `<div class="math math-display" data-tex="${escapeHTML(t.text)}">${escapeHTML(t.raw)}</div>\n`,
      },
      {
        name: "mathInline",
        level: "inline",
        start: (src) => { const i = src.indexOf("$"); return i < 0 ? undefined : i; },
        tokenizer(src) {
          let m = /^\$\$(?!\s)([^$]+?)\$\$/.exec(src);
          if (m) return { type: "mathInline", raw: m[0], text: m[1], display: true };
          // Opening $ not followed by a space, closing $ not preceded by one nor followed by a digit,
          // so "costs $5 and $10" stays plain text. (No lookbehind: macOS 13.0's WebKit lacks it.)
          m = /^\$(?![\s$])((?:\\.|[^\\$\n])+?)\$(?!\d)/.exec(src);
          if (m && !/\s$/.test(m[1])) return { type: "mathInline", raw: m[0], text: m[1], display: false };
        },
        renderer: (t) =>
          `<span class="math${t.display ? " math-display" : ""}" data-tex="${escapeHTML(t.text)}">${escapeHTML(t.raw)}</span>`,
      },
    ],
  };

  marked.use({ gfm: true }, markedFootnote({ description: "Footnotes" }), math);
  hljs.configure({ ignoreUnescapedHTML: true });

  // ---------- post-processing ----------

  // Markdown can contain raw HTML; drop anything that could run code or escape the page.
  function sanitize(root) {
    root.querySelectorAll("script, iframe, frame, object, embed, form, meta, link, base, style")
      .forEach((el) => el.remove());
    for (const el of root.querySelectorAll("*")) {
      for (const attr of [...el.attributes]) {
        const name = attr.name.toLowerCase();
        if (name.startsWith("on") || name === "srcdoc") {
          el.removeAttribute(attr.name);
        } else if (["href", "src", "xlink:href", "action", "formaction", "poster"].includes(name)
                   && /^\s*(javascript|vbscript|data:text\/html)/i.test(attr.value)) {
          el.removeAttribute(attr.name);
        }
      }
    }
  }

  function enhance(root) {
    // Heading anchors
    const used = new Map();
    root.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach((h) => {
      if (!h.id) h.id = slugify(h.textContent, used);
      const a = document.createElement("a");
      a.className = "anchor";
      a.href = "#" + h.id;
      a.setAttribute("aria-hidden", "true");
      h.prepend(a);
    });

    // GitHub-style alerts: > [!NOTE]
    root.querySelectorAll("blockquote").forEach((bq) => {
      const p = bq.firstElementChild;
      if (!p || p.tagName !== "P") return;
      const m = p.innerHTML.match(/^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(<br>)?\s*/i);
      if (!m) return;
      const kind = m[1].toUpperCase();
      p.innerHTML = p.innerHTML.slice(m[0].length);
      if (!p.innerHTML.trim()) p.remove();
      const title = document.createElement("p");
      title.className = "alert-title";
      title.textContent = ALERTS[kind];
      bq.prepend(title);
      bq.classList.add("alert", "alert-" + kind.toLowerCase());
    });

    // Code blocks: diagrams, math, syntax highlighting + copy button
    root.querySelectorAll("pre > code").forEach((code) => {
      const m = /language-([\w+#.-]+)/.exec(code.className);
      const lang = m && m[1].toLowerCase();
      const pre = code.parentElement;
      if (lang === "mermaid") {
        const block = document.createElement("div");
        block.className = "mermaid-block";
        block.dataset.src = code.textContent;
        pre.replaceWith(block);
        block.append(pre);
        return;
      }
      if (lang === "math") {
        const div = document.createElement("div");
        div.className = "math math-display";
        div.dataset.tex = code.textContent.trim();
        div.textContent = code.textContent;
        pre.replaceWith(div);
        return;
      }
      if (lang && hljs.getLanguage(lang)) {
        try { hljs.highlightElement(code); } catch (_) {}
      }
      const btn = document.createElement("button");
      btn.className = "copy-btn";
      btn.type = "button";
      btn.textContent = "Copy";
      pre.append(btn);
      if (lang) pre.dataset.lang = lang;
    });

    // Task lists
    root.querySelectorAll("li input[type=checkbox]").forEach((cb) => {
      cb.disabled = true;
      cb.closest("li").classList.add("task-item");
      cb.closest("ul, ol")?.classList.add("task-list");
    });

    // Wide tables scroll horizontally instead of overflowing the page
    root.querySelectorAll("table").forEach((t) => {
      const wrap = document.createElement("div");
      wrap.className = "table-wrap";
      t.replaceWith(wrap);
      wrap.append(t);
    });
  }

  // ---------- lazy extras: KaTeX & Mermaid ----------

  async function renderMath(root) {
    const els = [...root.querySelectorAll(".math[data-tex]")];
    if (!els.length) return;
    loadStyle("vendor/katex/katex.min.css");
    await loadScript("vendor/katex/katex.min.js");
    for (const el of els) {
      try {
        katex.render(el.dataset.tex, el, {
          displayMode: el.classList.contains("math-display"),
          throwOnError: false,
          output: "htmlAndMathml",
        });
      } catch (_) { /* leave the raw TeX visible */ }
    }
  }

  let diagramSeq = 0;
  let diagramTheme = null;
  let diagramQueue = Promise.resolve();

  // Mermaid can't run two renders at once, so queue them.
  function renderDiagrams(root, theme) {
    const run = diagramQueue.then(() => drawDiagrams(root, theme));
    diagramQueue = run.catch(() => {});
    return run;
  }

  async function drawDiagrams(root, theme) {
    const blocks = [...root.querySelectorAll(".mermaid-block")];
    if (!blocks.length) return;
    await loadScript("vendor/mermaid.tiny.js");
    theme = theme || (prefersDark() ? "dark" : "default");
    if (theme !== diagramTheme) {
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        theme,
        fontFamily: getComputedStyle(document.body).fontFamily,
      });
      diagramTheme = theme;
    }
    for (const block of blocks) {
      try {
        const { svg } = await mermaid.render("mdr-diagram-" + ++diagramSeq, block.dataset.src);
        block.innerHTML = svg;
        block.classList.remove("failed");
      } catch (err) {
        block.classList.add("failed");
        block.innerHTML = `<pre><code>${escapeHTML(block.dataset.src)}</code></pre>` +
          `<p class="diagram-error">Diagram error: ${escapeHTML(String(err?.message || err))}</p>`;
      }
    }
  }

  // ---------- outline & scroll spy ----------

  let activeHeading = null;

  function headings() {
    return content.classList.contains("markdown-body")
      ? [...content.querySelectorAll("h1, h2, h3, h4")].filter((h) => !h.closest(".footnotes"))
      : [];
  }

  function sendOutline() {
    const items = headings().map((h) => ({
      id: h.id, level: Number(h.tagName[1]), text: h.textContent.trim(),
    }));
    activeHeading = null;
    post({ type: "outline", items });
    updateActive();
  }

  function updateActive() {
    let current = null;
    const all = headings();
    const atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4;
    if (atBottom && window.scrollY > 0 && all.length) {
      // Short final sections never reach the top of the window; count them once we're at the end.
      current = all[all.length - 1].id;
    } else {
      for (const h of all) {
        if (h.getBoundingClientRect().top <= 90) current = h.id;
        else break;
      }
    }
    if (current !== activeHeading) {
      activeHeading = current;
      post({ type: "active", id: current || "" });
    }
  }

  // ---------- render ----------

  let renderToken = 0;
  let lastRender = Promise.resolve();

  function restoreScroll(y) {
    if (y < 0) return;
    window.scrollTo(0, y);
    // Images may still be loading; try again once layout settles.
    requestAnimationFrame(() => window.scrollTo(0, y));
    setTimeout(() => window.scrollTo(0, y), 120);
  }

  async function render(p) {
    const token = ++renderToken;
    clearFind();
    if (p.clear) {
      content.replaceChildren();
      content.className = "";
      sendOutline();
      return;
    }
    setBase(p.base);
    document.title = p.title || "";

    if (p.error) {
      content.className = "markdown-body";
      const div = document.createElement("div");
      div.className = "error";
      div.textContent = p.error;
      content.replaceChildren(div);
    } else if (p.source) {
      content.className = "source-view";
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      if (p.md.length < 400000) {
        code.innerHTML = hljs.highlight(p.md, { language: "markdown", ignoreIllegals: true }).value;
      } else {
        code.textContent = p.md;
      }
      pre.append(code);
      content.replaceChildren(pre);
    } else {
      content.className = "markdown-body";
      content.replaceChildren(renderMarkdown(p.md));
    }
    sendOutline();
    const reposition = () => {
      if (!(p.anchor && scrollToAnchor(p.anchor))) restoreScroll(p.scroll);
    };
    reposition();

    // Images, math and diagrams change the layout after the first paint; jump again once they're in,
    // unless the reader has started scrolling in the meantime.
    const pending = [...content.querySelectorAll("img")].filter((img) => !img.complete);
    const hasExtras = !!content.querySelector(".math, .mermaid-block");
    if (!pending.length && !hasExtras) return;
    const startY = window.scrollY;
    await Promise.allSettled([
      renderMath(content),
      renderDiagrams(content),
      imagesLoaded(pending, 2000),
    ]);
    if (token !== renderToken || Math.abs(window.scrollY - startY) > 40) return;
    reposition();
    updateActive();
  }

  function imagesLoaded(images, timeout) {
    if (!images.length) return Promise.resolve();
    const all = Promise.all(images.map((img) => new Promise((resolve) => {
      img.addEventListener("load", resolve, { once: true });
      img.addEventListener("error", resolve, { once: true });
    })));
    return Promise.race([all, new Promise((resolve) => setTimeout(resolve, timeout))]);
  }

  function renderMarkdown(md) {
    const [front, body] = splitFrontMatter(md);
    const tpl = document.createElement("template");
    tpl.innerHTML = marked.parse(body);
    sanitize(tpl.content);
    enhance(tpl.content);
    if (front) {
      const details = document.createElement("details");
      details.className = "front-matter";
      const summary = document.createElement("summary");
      summary.textContent = "Front matter";
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      code.innerHTML = hljs.highlight(front, { language: "yaml", ignoreIllegals: true }).value;
      pre.append(code);
      details.append(summary, pre);
      tpl.content.prepend(details);
    }
    return tpl.content;
  }

  // ---------- find in page ----------

  const found = { marks: [], index: -1 };

  function status() {
    return { current: found.marks.length ? found.index + 1 : 0, total: found.marks.length };
  }

  function clearFind() {
    const parents = new Set();
    for (const m of found.marks) {
      if (!m.parentNode) continue;
      parents.add(m.parentNode);
      m.replaceWith(document.createTextNode(m.textContent));
    }
    parents.forEach((p) => p.normalize());
    found.marks = [];
    found.index = -1;
  }

  function focusMatch() {
    found.marks.forEach((m, i) => m.classList.toggle("current", i === found.index));
    const el = found.marks[found.index];
    if (!el) return;
    el.closest("details")?.setAttribute("open", "");
    el.scrollIntoView?.({ block: "center" });
  }

  function find(query) {
    clearFind();
    if (!query) return status();
    const needle = query.toLowerCase();
    const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) =>
        n.nodeValue.toLowerCase().includes(needle) && !n.parentElement.closest("button, svg, .katex")
          ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const node of nodes) {
      const text = node.nodeValue;
      const lower = text.toLowerCase();
      const frag = document.createDocumentFragment();
      let from = 0, at;
      while ((at = lower.indexOf(needle, from)) !== -1) {
        frag.append(text.slice(from, at));
        const mark = document.createElement("mark");
        mark.className = "mdr-find";
        mark.textContent = text.slice(at, at + needle.length);
        frag.append(mark);
        found.marks.push(mark);
        from = at + needle.length;
      }
      frag.append(text.slice(from));
      node.replaceWith(frag);
    }
    if (found.marks.length) {
      found.index = 0;
      focusMatch();
    }
    return status();
  }

  function findStep(dir) {
    const n = found.marks.length;
    if (!n) return status();
    found.index = (found.index + dir + n) % n;
    focusMatch();
    return status();
  }

  // ---------- export ----------

  // Rendered HTML without reader UI, with image URLs made absolute.
  async function exportHTML() {
    await lastRender;
    const clone = content.cloneNode(true);
    clone.querySelectorAll(".copy-btn, .anchor, .front-matter").forEach((el) => el.remove());
    clone.querySelectorAll("mark.mdr-find").forEach((m) => m.replaceWith(m.textContent));
    const images = [];
    const live = content.querySelectorAll("img[src]");
    clone.querySelectorAll("img[src]").forEach((img, i) => {
      const abs = live[i]?.src || img.src;
      img.setAttribute("src", abs);
      if (abs.startsWith("file:")) images.push(abs);
    });
    clone.querySelectorAll("a[href]").forEach((a) => {
      const href = a.getAttribute("href");
      if (!href.startsWith("#")) a.setAttribute("href", a.href);
    });
    return {
      html: clone.innerHTML,
      text: content.innerText,
      title: document.title,
      images,
      hasMath: !!clone.querySelector(".katex"),
    };
  }

  // PDFs are always light: redraw dark diagrams with the light theme while printing.
  async function preparePrint() {
    await lastRender;
    if (diagramTheme === "dark") await renderDiagrams(content, "default");
  }

  async function afterPrint() {
    if (prefersDark() && diagramTheme === "default") await renderDiagrams(content, "dark");
  }

  // ---------- events ----------

  function setOptions(o) {
    if (o.font) document.body.dataset.font = o.font;
    if (o.width !== undefined) {
      document.documentElement.style.setProperty("--content-width", o.width > 0 ? o.width + "px" : "none");
    }
  }

  document.addEventListener("click", (e) => {
    const btn = e.target.closest(".copy-btn");
    if (btn) {
      const code = btn.parentElement.querySelector("code");
      post({ type: "copy", text: code ? code.textContent : "" });
      btn.textContent = "Copied";
      btn.classList.add("done");
      setTimeout(() => { btn.textContent = "Copy"; btn.classList.remove("done"); }, 1200);
      return;
    }
    const a = e.target.closest("a[href]");
    if (!a) return;
    e.preventDefault();
    const href = a.getAttribute("href");
    if (href.startsWith("#")) {
      scrollToAnchor(href.slice(1), true);
      return;
    }
    post({ type: "link", href: a.href });
  });

  let scrollTimer = null;
  window.addEventListener("scroll", () => {
    if (scrollTimer) return;
    scrollTimer = setTimeout(() => {
      scrollTimer = null;
      post({ type: "scroll", y: window.scrollY });
      updateActive();
    }, 120);
  }, { passive: true });

  window.matchMedia?.("(prefers-color-scheme: dark)").addEventListener?.("change", () => {
    if (content.querySelector(".mermaid-block")) renderDiagrams(content);
  });

  document.addEventListener("DOMContentLoaded", () => {
    content = document.getElementById("content");
  });

  window.mdr = {
    render: (p) => (lastRender = render(p).catch(() => {})),
    setOptions, find, findStep, clearFind, exportHTML, preparePrint, afterPrint,
    scrollToAnchor: (id) => scrollToAnchor(id, true),
  };
})();
