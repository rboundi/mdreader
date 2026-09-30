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
    if (target) reveal(target);
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

  const URL_ATTRS = ["href", "src", "xlink:href", "action", "formaction", "poster", "srcset"];
  const SAFE_PROTOCOLS = ["http:", "https:", "mailto:", "file:"];

  // Parse the URL the way the browser will (tabs/newlines inside "javascript:" included)
  // and only keep the protocols a document legitimately links to.
  function isSafeURL(value, name) {
    const v = value.trim();
    if (v.startsWith("#")) return true;
    if (name === "src" && /^data:image\/(png|jpe?g|gif|webp|avif|bmp)[;,]/i.test(v)) return true;
    try {
      return SAFE_PROTOCOLS.includes(new URL(v, document.baseURI).protocol);
    } catch (_) {
      return false;
    }
  }

  // Markdown can contain raw HTML; drop anything that could run code or escape the page.
  function sanitize(root) {
    root.querySelectorAll(
      "script, iframe, frame, object, embed, form, meta, link, base, style, animate, set, animateMotion, animateTransform",
    ).forEach((el) => el.remove());
    for (const el of root.querySelectorAll("*")) {
      for (const attr of [...el.attributes]) {
        const name = attr.name.toLowerCase();
        if (name.startsWith("on") || name === "srcdoc") {
          el.removeAttribute(attr.name);
        } else if (URL_ATTRS.includes(name) && name !== "srcset" && !isSafeURL(attr.value, name)) {
          el.removeAttribute(attr.name);
        } else if (name === "srcset" && /(javascript|vbscript|data):/i.test(attr.value.replace(/[\x00-\x20]/g, ""))) {
          el.removeAttribute(attr.name);
        }
      }
    }
  }

  function enhance(root) {
    // Heading anchors. Ids written in raw HTML count as taken, so every heading id stays unique.
    const used = new Map();
    const taken = new Set();
    root.querySelectorAll("[id]:not(h1, h2, h3, h4, h5, h6)").forEach((el) => taken.add(el.id));
    root.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach((h) => {
      if (!h.id || taken.has(h.id)) {
        let id;
        do { id = slugify(h.textContent, used); } while (taken.has(id));
        h.id = id;
      }
      taken.add(h.id);
      if (h.closest(".footnotes")) return;
      const fold = document.createElement("button");
      fold.className = "fold";
      fold.type = "button";
      fold.setAttribute("aria-label", "Collapse section");
      h.prepend(fold);
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
  function renderDiagrams(root, theme, token) {
    const run = diagramQueue.then(() => (token === undefined || token === renderToken) && drawDiagrams(root, theme));
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
        if (h.classList.contains("folded-away")) continue;
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
    updateProgress();
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
      renderDiagrams(content, undefined, token),
      imagesLoaded(pending, 2000),
    ]);
    if (token !== renderToken || Math.abs(window.scrollY - startY) > 40) return;
    reposition();
    updateActive();
    updateProgress();
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
    reveal(el);
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
    clone.querySelectorAll(".copy-btn, .fold, .front-matter").forEach((el) => el.remove());
    clone.querySelectorAll(".folded-away, .collapsed").forEach((el) => el.classList.remove("folded-away", "collapsed"));
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
    // innerText needs a laid-out element, so measure the cleaned copy off-screen.
    clone.style.cssText = "position:absolute;left:-100000px;top:0;width:800px";
    document.body.append(clone);
    const text = clone.innerText ?? clone.textContent;
    clone.remove();
    clone.removeAttribute("style");
    return {
      html: clone.innerHTML,
      text,
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

  // ---------- collapsible sections ----------

  const headingLevel = (el) => (/^H[1-6]$/.test(el.tagName) ? Number(el.tagName[1]) : 0);

  // Hide everything after a collapsed heading up to the next heading of the same or higher level.
  function applyFolds() {
    let hideBelow = 0;
    for (const child of content.children) {
      const level = headingLevel(child);
      if (level && hideBelow && level <= hideBelow) hideBelow = 0;
      child.classList.toggle("folded-away", hideBelow > 0);
      if (level && !hideBelow && child.classList.contains("collapsed")) hideBelow = level;
    }
    updateProgress();
  }

  function toggleFold(heading) {
    heading.classList.toggle("collapsed");
    heading.querySelector(".fold")?.setAttribute(
      "aria-label", heading.classList.contains("collapsed") ? "Expand section" : "Collapse section");
    applyFolds();
  }

  // Expand whatever collapsed sections contain `el`.
  function reveal(el) {
    let block = el;
    while (block.parentElement && block.parentElement !== content) block = block.parentElement;
    if (block.parentElement !== content) return;
    let limit = headingLevel(block) || 7;
    let changed = false;
    for (let prev = block.previousElementSibling; prev && limit > 1; prev = prev.previousElementSibling) {
      const level = headingLevel(prev);
      if (!level || level >= limit) continue;
      if (prev.classList.contains("collapsed")) {
        prev.classList.remove("collapsed");
        changed = true;
      }
      limit = level;
    }
    if (changed) applyFolds();
  }

  // ---------- reading progress ----------

  let progressBar = null;
  let progressQueued = false;

  function updateProgress() {
    if (progressQueued || !progressBar) return;
    progressQueued = true;
    requestAnimationFrame(() => {
      progressQueued = false;
      const max = document.documentElement.scrollHeight - window.innerHeight;
      progressBar.style.transform = `scaleX(${max > 0 ? Math.min(1, window.scrollY / max) : 0})`;
      progressBar.hidden = max <= 0;
    });
  }

  // ---------- image zoom ----------

  function openLightbox(img) {
    const box = document.createElement("div");
    box.className = "lightbox";
    const big = document.createElement("img");
    big.src = img.currentSrc || img.src;
    big.alt = img.alt;
    box.append(big);
    box.addEventListener("click", () => box.remove());
    document.body.append(box);
  }

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") document.querySelector(".lightbox")?.remove();
  });

  // ---------- events ----------

  function setOptions(o) {
    if (o.font) document.body.dataset.font = o.font;
    if (o.theme !== undefined) {
      if (o.theme) document.documentElement.dataset.theme = o.theme;
      else delete document.documentElement.dataset.theme;
    }
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
    const fold = e.target.closest(".fold");
    if (fold) {
      toggleFold(fold.parentElement);
      return;
    }
    const a = e.target.closest("a[href]");
    const img = e.target.closest(".markdown-body img");
    if (img && !a) {
      openLightbox(img);
      return;
    }
    if (!a) return;
    e.preventDefault();
    const href = a.getAttribute("href");
    // The app records the position we're leaving, for Back and Forward.
    if (href.startsWith("#")) {
      post({ type: "anchor", y: window.scrollY });
      scrollToAnchor(href.slice(1), true);
      return;
    }
    post({ type: "link", href: a.href, y: window.scrollY });
  });

  // Tell the app which heading was right-clicked, for "Copy Link to Heading".
  document.addEventListener("contextmenu", (e) => {
    const h = e.target.closest?.(".markdown-body :is(h1, h2, h3, h4, h5, h6)");
    post({ type: "context", heading: h && !h.closest(".footnotes") ? h.id : "" });
  });

  let scrollTimer = null;
  window.addEventListener("scroll", () => {
    if (scrollTimer) return;
    updateProgress();
    scrollTimer = setTimeout(() => {
      scrollTimer = null;
      post({ type: "scroll", y: window.scrollY });
      updateActive();
    }, 120);
  }, { passive: true });

  window.matchMedia?.("(prefers-color-scheme: dark)").addEventListener?.("change", () => {
    if (content.querySelector(".mermaid-block")) renderDiagrams(content);
  });

  window.addEventListener("resize", updateProgress);

  document.addEventListener("DOMContentLoaded", () => {
    content = document.getElementById("content");
    progressBar = document.createElement("div");
    progressBar.id = "progress";
    progressBar.hidden = true;
    document.body.append(progressBar);
  });

  window.mdr = {
    render: (p) => (lastRender = render(p).catch(() => {})),
    setOptions, find, findStep, clearFind, exportHTML, preparePrint, afterPrint,
    scrollToAnchor: (id) => scrollToAnchor(id, true),
    scrollTo: (y) => window.scrollTo(0, y),
    scrollY: () => window.scrollY,
  };
})();
