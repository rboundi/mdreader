(() => {
  "use strict";

  const post = (msg) => window.webkit?.messageHandlers?.mdr?.postMessage(msg);
  // Resolve bundled files against app.js itself — <base> is repointed at each document's folder.
  const ROOT = (document.currentScript?.src || location.href).replace(/[^/]*$/, "");
  let content = document.getElementById("content");

  // GitHub alerts and Obsidian callouts: written type → style.
  const CALLOUTS = {
    note: "note", info: "info", todo: "todo", abstract: "abstract", summary: "abstract", tldr: "abstract",
    tip: "tip", hint: "tip", important: "important", success: "success", check: "success", done: "success",
    question: "question", help: "question", faq: "question", warning: "warning", attention: "warning",
    caution: "caution", failure: "failure", fail: "failure", missing: "failure", danger: "danger",
    error: "danger", bug: "bug", example: "example", quote: "quote", cite: "quote",
  };
  const CALLOUT_LABELS = { tldr: "TL;DR", faq: "FAQ", todo: "To do" };
  const CIRCLE = '<circle cx="12" cy="12" r="9"/>';
  const ICONS = {
    note: CIRCLE + '<path d="M12 11v5M12 8h.01"/>',
    info: CIRCLE + '<path d="M12 11v5M12 8h.01"/>',
    todo: '<rect x="4" y="4" width="16" height="16" rx="3"/><path d="M8.5 12l2.5 2.5 4.5-5"/>',
    abstract: '<rect x="5" y="4" width="14" height="17" rx="2"/><path d="M9 9h6M9 13h6M9 17h4"/>',
    tip: '<path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2V16h5v-.1c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z"/>',
    important: '<path d="M4 5h16v11H9l-5 4z"/><path d="M12 8v3M12 13.5h.01"/>',
    success: CIRCLE + '<path d="M8 12.5l2.8 2.8L16 10"/>',
    question: CIRCLE + '<path d="M9.5 9.5a2.5 2.5 0 1 1 3.4 2.3c-.6.3-.9.8-.9 1.4v.3M12 16.5h.01"/>',
    warning: '<path d="M12 4l9 16H3z"/><path d="M12 10v4M12 17h.01"/>',
    caution: '<path d="M8.3 3h7.4L21 8.3v7.4L15.7 21H8.3L3 15.7V8.3z"/><path d="M12 8v5M12 16h.01"/>',
    failure: CIRCLE + '<path d="M9 9l6 6M15 9l-6 6"/>',
    danger: '<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>',
    bug: '<rect x="8" y="7" width="8" height="13" rx="4"/><path d="M12 7V4M4 11h4M16 11h4M4 17h4M16 17h4M12 11v9"/>',
    example: '<path d="M9 6h11M9 12h11M9 18h11M4.5 6h.01M4.5 12h.01M4.5 18h.01"/>',
    quote: '<path d="M5 17c2-1 3-3 3-6V7H4v4h4M14 17c2-1 3-3 3-6V7h-4v4h4"/>',
  };
  const EMOJI = new Map((window.MDR_EMOJI || "").split(/[|\n]/).filter(Boolean).map((pair) => {
    const i = pair.indexOf(" ");
    return [pair.slice(0, i), pair.slice(i + 1)];
  }));

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

  // A heading's id without the de-duplication suffix, for links written by hand.
  const plainSlug = (text) => slugify(text, new Map());

  function splitFrontMatter(md) {
    const m = md.match(/^---[ \t]*\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/);
    return m ? [m[1], md.slice(m[0].length)] : [null, md];
  }

  function anchorTarget(id) {
    let target = document.getElementById(id) || document.getElementsByName(id)[0];
    if (!target) {
      try { target = document.getElementById(decodeURIComponent(id)); } catch (_) {}
    }
    return target || null;
  }

  function scrollToAnchor(id, smooth) {
    if (!id) return false;
    // Outline entries in source view point at the heading's line.
    const sourceIndex = current.source && /^source-(\d+)$/.exec(id);
    if (sourceIndex) {
      const heading = sourceHeadings(current.md)[Number(sourceIndex[1])];
      const y = heading && sourceOffsetY(heading.offset);
      if (y == null) return false;
      window.scrollTo({ top: Math.max(0, y - 12), behavior: smooth ? "smooth" : "auto" });
      return true;
    }
    const target = anchorTarget(id);
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

  // [[Note]], [[Note|label]], [[Note#Heading]] and [[#Heading]] link to Note.md next to the document;
  // ![[image.png]] shows the image.
  const FILE_EXTENSION = /\.(md|markdown|mdown|mkdn?|mdwn|txt|text|png|jpe?g|gif|webp|avif|heic|svg|bmp|tiff?|pdf|csv|json|html?|mp[34]|m4a|mov|wav)$/i;
  const IMAGE_EXTENSION = /\.(png|jpe?g|gif|webp|avif|heic|svg|bmp|tiff?)$/i;
  const wikiLinks = {
    extensions: [{
      name: "wikiLink",
      level: "inline",
      start(src) {
        const i = src.indexOf("[[");
        if (i < 0) return undefined;
        return i > 0 && src[i - 1] === "!" ? i - 1 : i;
      },
      tokenizer(src) {
        if (this.lexer.state.inLink) return;
        // Not followed by "(" or "[", so citation-style links like [[1]](url) keep working.
        const m = /^(!?)\[\[([^[\]|\n]+?)(?:\|([^[\]\n]+?))?\]\](?![([])/.exec(src);
        if (!m || !m[2].replace(/#/g, "").trim() || m[2] === "_TOC_") return;
        return { type: "wikiLink", raw: m[0], embed: !!m[1], target: m[2].trim(), label: m[3]?.trim() };
      },
      renderer(t) {
        const hash = t.target.indexOf("#");
        const name = hash < 0 ? t.target : t.target.slice(0, hash).trim();
        const heading = hash < 0 ? "" : t.target.slice(hash + 1).trim();
        let href = name.split("/").map(encodeURIComponent).join("/");
        if (t.embed && IMAGE_EXTENSION.test(name)) {
          return `<img src="${escapeHTML(href)}" alt="${escapeHTML(t.label || name)}">`;
        }
        if (name && !FILE_EXTENSION.test(name)) href += ".md";
        if (heading) href += "#" + encodeURIComponent(plainSlug(heading));
        const label = t.label || (name && heading ? `${name} › ${heading}` : name || heading);
        return `${t.embed ? "!" : ""}<a class="wikilink" href="${escapeHTML(href)}">${escapeHTML(label)}</a>`;
      },
    }],
  };

  // True when the text just before this point ends in a letter, digit, "=" or ":".
  const followsWord = (tokens) => /[\p{L}\p{N}=:]$/u.test(tokens?.[tokens.length - 1]?.raw || "");

  // ==highlighted text==
  const highlights = {
    extensions: [{
      name: "highlight",
      level: "inline",
      // Not right after a letter or digit, so "a==b" and base64 padding stay as they are.
      start: (src) => {
        const m = /(^|[^\p{L}\p{N}=])==[^\s=]/u.exec(src);
        return m ? m.index + m[1].length : undefined;
      },
      tokenizer(src, tokens) {
        if (followsWord(tokens)) return;
        const m = /^==(?=[^\s=])([^\n`]*?[^\s=`])==(?![=\p{L}\p{N}])/u.exec(src);
        if (m) return { type: "highlight", raw: m[0], tokens: this.lexer.inlineTokens(m[1]) };
      },
      renderer(t) { return `<mark class="highlight">${this.parser.parseInline(t.tokens)}</mark>`; },
    }],
  };

  // :tada: and the other GitHub emoji shortcodes in emoji.js.
  const emoji = {
    extensions: [{
      name: "emoji",
      level: "inline",
      start: (src) => {
        const m = /(^|[^\p{L}\p{N}:])(:[a-z0-9_+-]+:)/u.exec(src);
        return m ? m.index + m[1].length : undefined;
      },
      tokenizer(src, tokens) {
        if (followsWord(tokens)) return;
        const m = /^:([a-z0-9_+-]+):(?![\p{L}\p{N}])/u.exec(src);
        if (m && EMOJI.has(m[1])) return { type: "emoji", raw: m[0], text: EMOJI.get(m[1]) };
      },
      renderer: (t) => t.text,
    }],
  };

  // An image alone in its paragraph becomes a figure captioned with its title or alt text.
  const captions = {
    renderer: {
      paragraph(token) {
        const t = token.tokens;
        if (t?.length !== 1 || t[0].type !== "image") return false;
        const caption = (t[0].title || t[0].text || "").trim();
        if (!caption) return false;
        return `<figure>${this.parser.parseInline(t)}<figcaption>${escapeHTML(caption)}</figcaption></figure>\n`;
      },
    },
  };

  marked.use({ gfm: true }, markedFootnote({ description: "Footnotes" }), math, wikiLinks, highlights, emoji, captions);
  // For locating headings in the source. Kept separate because lexing with the footnote extension
  // outside marked.parse leaves it in a broken state for the next document.
  const placeLexer = new marked.Marked({ gfm: true }, math);
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
      // "#" on hover copies a link to the heading. The button has no text, so textContent is unchanged.
      if (!h.closest(".footnotes")) {
        const link = document.createElement("button");
        link.className = "anchor-link";
        link.type = "button";
        link.setAttribute("aria-label", "Copy link to heading");
        h.append(link);
      }
      // Only top-level headings can fold; ones inside HTML blocks, lists or quotes can't.
      if (h.parentNode !== root) return;
      const fold = document.createElement("button");
      fold.className = "fold";
      fold.type = "button";
      fold.setAttribute("aria-label", "Collapse section");
      h.prepend(fold);
    });

    // Alerts and callouts: > [!NOTE], > [!tip] Custom title, > [!faq]- (starts collapsed)
    root.querySelectorAll("blockquote").forEach((bq) => {
      const p = bq.firstElementChild;
      const first = p?.tagName === "P" ? p.firstChild : null;
      const m = first?.nodeType === Node.TEXT_NODE && /^\s*\[!([a-z-]+)\]([+-]?)/i.exec(first.nodeValue);
      if (!m) return;
      const word = m[1].toLowerCase();
      const kind = CALLOUTS[word] || "note";
      first.nodeValue = first.nodeValue.slice(m[0].length).replace(/^[ \t]+/, "");
      // The rest of the first line is the title: move those nodes, up to the line break, into it.
      const label = document.createElement("span");
      while (p.firstChild) {
        const node = p.firstChild;
        if (node.nodeName === "BR") { node.remove(); break; }
        if (node.nodeType === Node.TEXT_NODE && node.nodeValue.includes("\n")) {
          const i = node.nodeValue.indexOf("\n");
          label.append(node.nodeValue.slice(0, i));
          node.nodeValue = node.nodeValue.slice(i + 1);
          break;
        }
        label.append(node);
      }
      if (!label.textContent.trim() && !label.querySelector("img")) {
        label.textContent = CALLOUT_LABELS[word] || word[0].toUpperCase() + word.slice(1);
      }
      if (!p.textContent.trim() && !p.querySelector("img")) p.remove();
      const foldable = !!m[2];
      const title = document.createElement(foldable ? "summary" : "p");
      title.className = "alert-title";
      title.innerHTML = `<svg class="alert-icon" viewBox="0 0 24 24" aria-hidden="true">${ICONS[kind]}</svg>`;
      title.append(label);
      let box = bq;
      if (foldable) {
        box = document.createElement("details");
        box.open = m[2] === "+";
        box.append(...bq.childNodes);
        bq.replaceWith(box);
      }
      box.prepend(title);
      box.classList.add("alert", "alert-" + kind);
    });

    // [TOC] (or [[_TOC_]]) on its own line becomes a table of contents.
    root.querySelectorAll("p").forEach((p) => {
      if (/^\s*(\[TOC\]|\[\[_?TOC_?\]\])\s*$/i.test(p.textContent) && !p.querySelector("a")) {
        p.replaceWith(tableOfContents(root));
      }
    });

    // Sortable tables: clicking a header sorts by that column.
    root.querySelectorAll("table thead th").forEach((th) => th.classList.add("sortable"));

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
      // One element per line, for optional line numbers.
      // (Not for code written as raw HTML with its own tags inside.)
      if (!code.querySelector(":not(span)")) {
        code.innerHTML = splitLines(code.innerHTML).map((line) => `<span class="line">${line}</span>`).join("");
      }
    });

    // Task lists
    root.querySelectorAll("li input[type=checkbox]").forEach((cb) => {
      // Markdown tasks (marked writes them disabled) can be ticked; clicking one updates the file.
      // A checkbox written as raw HTML isn't a task and stays inert.
      // Footnotes are moved to the end of the page, out of file order, so their tasks stay inert too.
      cb.classList.toggle("task-box", cb.disabled && !cb.closest(".footnotes, [data-footnotes]"));
      cb.disabled = !cb.classList.contains("task-box");
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
    if (typeof mermaid === "undefined") {
      // The bundled Mermaid needs the WebKit in macOS 13.3 or later.
      for (const block of blocks) {
        if (block.querySelector(".diagram-error")) continue;
        block.classList.add("failed");
        block.insertAdjacentHTML("beforeend", '<p class="diagram-error">Diagrams need macOS 13.3 or later.</p>');
      }
      return;
    }
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

  // Optional 1, 1.1, 1.2 numbering of the outline headings. A lone h1 at the top is the
  // document's title and isn't numbered.
  function numberHeadings() {
    const hs = headings();
    hs.forEach((h) => h.removeAttribute("data-num"));
    if (!options.numbers) return;
    const h1s = hs.filter((h) => h.tagName === "H1");
    const list = h1s.length === 1 && hs[0] === h1s[0] ? hs.slice(1) : hs;
    if (!list.length) return;
    const base = Math.min(...list.map(headingLevel));
    const counters = [];
    for (const h of list) {
      const depth = headingLevel(h) - base;
      counters[depth] = (counters[depth] || 0) + 1;
      counters.length = depth + 1;
      h.dataset.num = Array.from(counters, (n) => n || 1).join(".");
    }
    for (const a of content.querySelectorAll(".toc a")) {
      const target = anchorTarget(a.getAttribute("href").slice(1));
      if (target?.dataset.num) a.dataset.num = target.dataset.num;
      else a.removeAttribute("data-num");
    }
  }

  function sendOutline() {
    const items = current.source
      ? sourceHeadings(current.md).map((h, i) => ({ id: "source-" + i, level: h.level, text: h.text }))
        .filter((h) => h.level <= 4)
      : headings().map((h) => ({
        id: h.id, level: Number(h.tagName[1]),
        text: (h.dataset.num ? h.dataset.num + " " : "") + h.textContent.trim(),
      }));
    activeHeading = null;
    post({ type: "outline", items });
    updateActive();
  }

  function updateActive() {
    let active = null;
    // [id, top relative to the window] of each outline heading.
    const stops = current.source ? headingStops() : [];
    const all = current.source
      ? sourceHeadings(current.md).map((h, i) => [h, i, stops[i]])
        .filter(([h, , y]) => h.level <= 4 && y !== undefined)
        .map(([, i, y]) => ["source-" + i, y + 12 - window.scrollY])
      : headings().filter((h) => !h.classList.contains("folded-away"))
        .map((h) => [h.id, h.getBoundingClientRect().top]);
    const atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4;
    if (atBottom && window.scrollY > 0 && all.length) {
      // Short final sections never reach the top of the window; count them once we're at the end.
      active = all[all.length - 1][0];
    } else {
      for (const [id, top] of all) {
        if (top <= 90) active = id;
        else break;
      }
    }
    if (active !== activeHeading) {
      activeHeading = active;
      post({ type: "active", id: active || "" });
    }
  }

  // ---------- render ----------

  let renderToken = 0;
  let tickedTask = false;
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
    // Switching between rendered and source view of the same document keeps the reader's place.
    const docKey = p.path || p.base + "|" + p.title;
    const sync = p.sync && current.doc === docKey && current.source !== !!p.source ? readPlace() : null;
    // The file changed on disk while showing: remember what it looked like to find the edit.
    sourceStops = null;
    const reloaded = p.scroll < 0 && current.doc === docKey && current.source === !!p.source
      && current.md !== (p.md || "");
    // A task the reader just ticked isn't an edit to jump to.
    const before = reloaded && !tickedTask ? { md: current.md, blocks: current.blocks } : null;
    tickedTask = false;
    clearFind();
    closeLightbox();
    hideFootnote();
    hideLinkStatus();
    leaveLink();
    // Re-rendering the same document (file changed on disk) keeps collapsed sections collapsed.
    // Re-rendering the same document keeps what's collapsed; otherwise use what the app remembered.
    const keepFolds = p.scroll < 0 && !p.source && current.doc === (p.path || p.base + "|" + p.title)
      ? [...content.querySelectorAll(".collapsed")].map((h) => h.id) : p.folds || [];
    if (p.clear) {
      content.replaceChildren();
      content.className = "";
      sendOutline();
      return;
    }
    setBase(p.base);
    document.title = p.title || "";

    let blocks = null;
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
      const html = p.md.length < 400000
        ? hljs.highlight(p.md, { language: "markdown", ignoreIllegals: true }).value
        : escapeHTML(p.md);
      code.innerHTML = splitLines(html).map((line) => `<span class="line">${line}</span>`).join("");
      pre.append(code);
      content.replaceChildren(pre);
    } else {
      content.className = "markdown-body";
      content.replaceChildren(renderMarkdown(p.md));
      numberHeadings();
      blocks = blockSnapshot();
      if (keepFolds.length) {
        keepFolds.forEach((id) => {
          const h = document.getElementById(id);
          if (h?.parentElement === content && h.querySelector(".fold")) setFold(h, true);
        });
        applyFolds();
      }
    }
    current = { doc: docKey, source: !!p.source, md: p.md || "", blocks };
    checkHorizontalScroll();
    sendOutline();
    updateProgress();
    checkLinks(token);
    const edit = before && options.followEdits && p.follow !== false ? findEdit(before) : null;
    let flash = true;
    const reposition = () => {
      if (sync) applyPlace(sync);
      else if (edit) { showEdit(edit, flash); flash = false; }
      else if (p.offset >= 0) applyOffset(p.offset);
      else if (!(p.anchor && scrollToAnchor(p.anchor))) restoreScroll(p.scroll);
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

  // ---------- following edits ----------

  // Top-level blocks as HTML, before math and diagrams are drawn, to compare with the next version.
  function blockSnapshot() {
    if (!options.followEdits || !content.classList.contains("markdown-body")) return null;
    // Front matter is left out: tools that stamp an "updated:" date on every save would otherwise
    // make every edit look like it's at the top.
    return [...content.children].map((el) => (el.classList.contains("front-matter") ? "" : el.outerHTML));
  }

  // The first block (rendered view) or character (source view) that differs from `before`.
  function findEdit(before) {
    if (current.source) {
      const a = before.md, b = current.md;
      let i = 0;
      while (i < a.length && i < b.length && a[i] === b[i]) i++;
      return { offset: i };
    }
    if (!before.blocks || !current.blocks) return null;
    const a = before.blocks, b = current.blocks;
    let i = 0;
    while (i < a.length && i < b.length && a[i] === b[i]) i++;
    if (i === a.length && i === b.length) return null;
    return { block: Math.min(i, b.length - 1) };
  }

  // Scrolls the edit into view if it isn't already, and highlights it briefly.
  function showEdit(edit, flash) {
    if (edit.offset !== undefined) {
      const y = sourceOffsetY(edit.offset);
      if (y !== null && (y < window.scrollY || y > window.scrollY + window.innerHeight - 40)) {
        window.scrollTo(0, Math.max(0, y - window.innerHeight / 3));
      }
      return;
    }
    // Sections the reader collapsed stay collapsed.
    const el = content.children[edit.block];
    if (!el || el.classList.contains("folded-away")) return;
    const r = el.getBoundingClientRect();
    if (r.top < 0 || r.top > window.innerHeight - 40) {
      window.scrollTo(0, Math.max(0, r.top + window.scrollY - window.innerHeight / 3));
    }
    if (flash) {
      el.classList.remove("just-edited");
      void el.offsetWidth;
      el.classList.add("just-edited");
      setTimeout(() => el.classList.remove("just-edited"), 1600);
    }
  }

  // ---------- broken links ----------

  const fileOf = (a) => a.href.replace(/[?#].*$/, "");

  // In-page anchors are checked here; the app checks that linked local files exist.
  function checkLinks(token) {
    if (!content.classList.contains("markdown-body")) return;
    const files = new Set();
    for (const a of content.querySelectorAll("a[href]")) {
      const href = a.getAttribute("href");
      if (href.startsWith("#")) {
        if (href.length > 1 && !anchorTarget(href.slice(1))) a.classList.add("broken");
      } else if (a.protocol === "file:") {
        files.add(fileOf(a));
      }
    }
    if (files.size) post({ type: "links", token, files: [...files].slice(0, 2000) });
  }

  function markBroken(token, missing) {
    if (token !== renderToken || !missing.length) return;
    const set = new Set(missing);
    for (const a of content.querySelectorAll("a[href]")) {
      if (a.protocol === "file:" && set.has(fileOf(a))) a.classList.add("broken");
    }
  }

  // Splits highlighted HTML into lines, closing and reopening the highlight spans at each line
  // break. Each line keeps its "\n", so character offsets in the source stay the same.
  function splitLines(html) {
    const lines = [];
    const open = [];
    let line = "";
    for (const [, tag, close, text] of html.matchAll(/(<span[^>]*>)|(<\/span>)|([^<]+)/g)) {
      if (tag) { open.push(tag); line += tag; continue; }
      if (close) { open.pop(); line += close; continue; }
      const parts = text.split("\n");
      parts.forEach((part, i) => {
        line += part;
        if (i < parts.length - 1) {
          lines.push(line + "\n" + "</span>".repeat(open.length));
          line = open.join("");
        }
      });
    }
    if (line.replace(/<[^>]*>/g, "")) lines.push(line);
    return lines;
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
    if (options.smart) smarten(tpl.content);
    if (front) {
      const details = document.createElement("details");
      details.className = "front-matter";
      const summary = document.createElement("summary");
      summary.textContent = "Front matter";
      const rows = frontMatterRows(front);
      if (rows) {
        details.open = true;
        details.append(summary, frontMatterTable(rows));
      } else {
        const pre = document.createElement("pre");
        const code = document.createElement("code");
        code.innerHTML = hljs.highlight(front, { language: "yaml", ignoreIllegals: true }).value;
        pre.append(code);
        details.append(summary, pre);
      }
      tpl.content.prepend(details);
    }
    return tpl.content;
  }

  // Simple YAML (keys with text, [a, b] or "- item" lists) as [{key, values, list}]; null for anything
  // more complex, which is then shown as YAML.
  function frontMatterRows(yaml) {
    const unquote = (v) => v.trim().replace(/^(["'])(.*)\1$/, "$2");
    const rows = [];
    for (const line of yaml.split(/\r?\n/)) {
      if (!line.trim() || /^\s*#/.test(line)) continue;
      const top = /^([\w][\w .-]*):(?:[ \t]+(.*))?$/.exec(line);
      if (top) {
        const value = (top[2] || "").trim();
        if (/^[|>{]/.test(value)) return null;
        const list = /^\[(.*)\]$/.exec(value);
        rows.push({
          key: top[1],
          list: !!list,
          values: list ? list[1].split(",").map(unquote).filter(Boolean) : value ? [unquote(value)] : [],
        });
        continue;
      }
      const item = /^\s+-\s+(.*)$/.exec(line);
      const last = rows[rows.length - 1];
      if (!item || !last || (last.values.length && !last.list) || /:\s/.test(item[1])) return null;
      last.list = true;
      last.values.push(unquote(item[1]));
    }
    return rows.length ? rows : null;
  }

  function frontMatterTable(rows) {
    const table = document.createElement("table");
    for (const row of rows) {
      const tr = table.insertRow();
      const th = document.createElement("th");
      th.textContent = row.key;
      const td = tr.insertCell();
      tr.prepend(th);
      if (row.list) {
        for (const value of row.values) {
          const chip = document.createElement("span");
          chip.className = "tag";
          chip.textContent = value;
          td.append(chip, " ");
        }
      } else {
        td.textContent = row.values.join(" ");
      }
    }
    return table;
  }

  // Nested list of links to the document's headings (a lone title at the top is left out).
  function tableOfContents(root) {
    const all = [...root.querySelectorAll("h1, h2, h3, h4")].filter((h) => !h.closest(".footnotes"));
    const h1s = all.filter((h) => h.tagName === "H1");
    const hs = h1s.length === 1 && all[0] === h1s[0] ? all.slice(1) : all;
    const nav = document.createElement("nav");
    nav.className = "toc";
    if (!hs.length) return nav;
    const base = Math.min(...hs.map(headingLevel));
    const lists = [document.createElement("ul")];
    nav.append(lists[0]);
    for (const h of hs) {
      const depth = headingLevel(h) - base;
      while (lists.length > depth + 1) lists.pop();
      while (lists.length < depth + 1) {
        const parent = lists[lists.length - 1];
        const holder = parent.lastElementChild || parent.appendChild(document.createElement("li"));
        lists.push(holder.appendChild(document.createElement("ul")));
      }
      const li = document.createElement("li");
      const a = document.createElement("a");
      a.href = "#" + encodeURIComponent(h.id);
      a.textContent = h.textContent.trim();
      li.append(a);
      lists[lists.length - 1].append(li);
    }
    return nav;
  }

  // ---------- smart punctuation ----------

  const SKIP_SMART = "code, pre, kbd, samp, .math, .katex, svg, .front-matter";
  const BLOCKS = "p, li, h1, h2, h3, h4, h5, h6, td, th, blockquote, dd, dt, figcaption, summary, div";

  // Curly quotes, en and em dashes, and ellipses in text (not code or math).
  function smarten(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let before = "";
    let block = null;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const here = node.parentElement?.closest(BLOCKS);
      if (here !== block) { before = ""; block = here; }
      // Code and web addresses stay as written, but still count as what came before.
      const skip = node.parentElement?.closest(SKIP_SMART) || /^(https?:\/\/|www\.)\S+$/.test(node.nodeValue.trim());
      if (!skip) node.nodeValue = smartText(node.nodeValue, before);
      before = node.nodeValue.slice(-1) || before;
    }
  }

  function smartText(s, before) {
    s = s.replace(/---/g, "—").replace(/--/g, "–").replace(/\.\.\./g, "…");
    let out = "";
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      const opening = /^$|[\s([{\u2014\u2013“‘"'-]/.test(i ? out[out.length - 1] : before);
      if (c === '"') out += opening ? "“" : "”";
      else if (c === "'") out += opening ? "‘" : "’";
      else out += c;
    }
    return out;
  }

  // ---------- previews of linked notes ----------

  let preview = null;
  let previewLink = null;
  let previewTimer = null;
  let previewSeq = 0;

  const isNoteLink = (a) => a.protocol === "file:" && !a.classList.contains("broken")
    && /\.(md|markdown|mdown|mkdn?|mdwn)$/i.test(a.pathname);

  function hoverLink(a) {
    if (a === previewLink) return;
    leaveLink();
    if (!isNoteLink(a) || a.closest(".link-preview")) return;
    previewLink = a;
    previewTimer = setTimeout(() => post({ type: "preview", href: a.href, seq: ++previewSeq }), 500);
  }

  function leaveLink() {
    clearTimeout(previewTimer);
    previewSeq++;  // a reply still on its way is for a link we've left
    previewLink = null;
    preview?.remove();
    preview = null;
  }

  // The start of the linked file, or the linked section, shown under the link.
  function showPreview(seq, md) {
    const a = previewLink;
    if (seq !== previewSeq || !a?.isConnected) return;
    preview?.remove();
    let fragment = "";
    try { fragment = decodeURIComponent(a.hash.slice(1)); } catch (_) {}
    const tpl = document.createElement("template");
    tpl.innerHTML = marked.parse(previewSection(md, fragment));
    sanitize(tpl.content);
    tpl.content.querySelectorAll("[id]").forEach((el) => el.removeAttribute("id"));
    tpl.content.querySelectorAll("img[src]").forEach((img) => {
      try { img.src = new URL(img.getAttribute("src"), a.href).href; } catch (_) {}
    });
    preview = document.createElement("div");
    preview.className = "footnote-tip link-preview markdown-body";
    preview.append(tpl.content);
    document.body.append(preview);
    const r = a.getBoundingClientRect();
    const width = Math.min(460, window.innerWidth - 32);
    preview.style.width = width + "px";
    preview.style.left = Math.max(16, Math.min(r.left - 20, window.innerWidth - width - 16)) + "px";
    preview.style.top = r.bottom + window.scrollY + 8 + "px";
  }

  function previewSection(md, fragment) {
    const [, body] = splitFrontMatter(md);
    const tokens = placeLexer.lexer(body);
    let start = 0;
    let end = tokens.length;
    if (fragment) {
      const used = new Map();
      const scratch = document.createElement("template");
      const found = tokens.findIndex((t) => {
        if (t.type !== "heading") return false;
        scratch.innerHTML = placeLexer.parseInline(t.text);
        const text = scratch.content.textContent;
        return slugify(text, used) === fragment || plainSlug(text) === fragment.toLowerCase();
      });
      if (found >= 0) {
        start = found;
        const next = tokens.findIndex((t, i) => i > found && t.type === "heading" && t.depth <= tokens[found].depth);
        if (next >= 0) end = next;
      }
    }
    let raw = "";
    for (let i = start; i < end && raw.length < 2500; i++) raw += tokens[i].raw;
    return raw;
  }

  // ---------- right-click: tables ----------

  // A table as tab- or comma-separated text, for Numbers or Excel.
  function tableText(index, csv) {
    const table = content.querySelectorAll(".markdown-body table")[index];
    if (!table) return null;
    const cell = (c) => {
      const t = c.textContent.trim().replace(/\s+/g, " ");
      return csv && /[",\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
    };
    return [...table.rows].map((row) => [...row.cells].map(cell).join(csv ? "," : "\t")).join("\n");
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

  // `scroll` is false when searching again after the page re-rendered, so the reader stays put.
  function find(query, scroll = true, index = 0) {
    clearFind();
    if (!query) return status();
    // With smart punctuation on, what's typed ("don't", "--") still finds what's shown (’, –).
    const fold = (s) => s.toLowerCase().replace(/[“”]/g, '"').replace(/[‘’]/g, "'");
    const needle = fold(options.smart
      ? query.replace(/---/g, "—").replace(/--/g, "–").replace(/\.\.\./g, "…") : query);
    const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) =>
        fold(n.nodeValue).includes(needle) && !n.parentElement.closest("button, svg, .katex")
          ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const node of nodes) {
      const text = node.nodeValue;
      const lower = fold(text);
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
      found.index = Math.min(Math.max(0, index), found.marks.length - 1);
      if (scroll) focusMatch();
      else found.marks[found.index].classList.add("current");
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
  // `plain` is for Word and RTF, whose converter drops checkboxes, math markup and drawings:
  // those become ☑/☐, the TeX source, and nothing.
  async function exportHTML(plain) {
    await preparePrint();  // light diagrams, like the PDF
    const clone = content.cloneNode(true);
    await afterPrint();
    if (plain) {
      clone.querySelectorAll("input[type=checkbox]").forEach((box) => box.replaceWith(box.checked ? "☑" : "☐"));
      clone.querySelectorAll(".math[data-tex]").forEach((el) => {
        const code = document.createElement("code");
        code.textContent = el.dataset.tex;
        el.replaceChildren(code);
      });
      clone.querySelectorAll(".mermaid-block, svg").forEach((el) => el.remove());
    }
    clone.querySelectorAll(".copy-btn, .fold, .anchor-link, .front-matter").forEach((el) => el.remove());
    clone.querySelectorAll("input.task-box").forEach((box) => { box.disabled = true; });
    clone.querySelectorAll(".folded-away, .collapsed").forEach((el) => el.classList.remove("folded-away", "collapsed"));
    clone.querySelectorAll("mark.mdr-find").forEach((m) => m.replaceWith(m.textContent));
    clone.querySelectorAll(".broken, .just-edited").forEach((el) => el.classList.remove("broken", "just-edited"));
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
      const level = headingLevel(child) || innerHeadingLevel(child);
      if (level && hideBelow && level <= hideBelow) hideBelow = 0;
      child.classList.toggle("folded-away", hideBelow > 0);
      if (headingLevel(child) && !hideBelow && child.classList.contains("collapsed")) hideBelow = level;
    }
    updateProgress();
    updateActive();
  }

  // Highest heading level inside a block such as <div align="center"><h1>…</h1></div>.
  function innerHeadingLevel(el) {
    const h = el.querySelector?.("h1, h2, h3, h4, h5, h6");
    if (!h || h.closest(".footnotes")) return 0;
    return Math.min(...[...el.querySelectorAll("h1, h2, h3, h4, h5, h6")].map(headingLevel));
  }

  function setFold(heading, collapsed) {
    heading.classList.toggle("collapsed", collapsed);
    heading.querySelector(".fold")?.setAttribute("aria-label", collapsed ? "Expand section" : "Collapse section");
  }

  // With ⌥, every section at the same level follows the clicked one.
  function toggleFold(heading, sameLevel) {
    const collapsed = !heading.classList.contains("collapsed");
    const targets = sameLevel
      ? topHeadings().filter((h) => h.tagName === heading.tagName && h.querySelector(".fold"))
      : [heading];
    targets.forEach((h) => setFold(h, collapsed));
    applyFolds();
    sendFolds();
  }

  function foldAll(collapsed) {
    if (!content.classList.contains("markdown-body")) return;
    topHeadings().filter((h) => h.querySelector(".fold")).forEach((h) => setFold(h, collapsed));
    applyFolds();
    sendFolds();
  }

  // The app remembers collapsed sections per file.
  function sendFolds() {
    post({ type: "folds", ids: [...content.querySelectorAll(":scope > .collapsed")].map((h) => h.id) });
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

  // ---------- sortable tables ----------

  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
  // Plain numbers like 12, 1,234.5, $10 or 45%; anything else (versions, dates) sorts as text.
  const asNumber = (s) => (/^[-+]?[$€£¥]?\s*(\d{1,3}(,\d{3})+|\d+)(\.\d+)?\s*%?$/.test(s)
    ? parseFloat(s.replace(/[^\d.+-]/g, "")) : NaN);

  // Ascending, then descending. Numbers (with currency or % signs) sort by value; empty cells last.
  function sortTable(th) {
    const table = th.closest("table");
    const body = table.tBodies[0];
    if (!body) return;
    const column = [...th.parentElement.children].indexOf(th);
    const descending = th.dataset.sort === "asc";
    table.querySelectorAll("th[data-sort]").forEach((h) => h.removeAttribute("data-sort"));
    th.dataset.sort = descending ? "desc" : "asc";
    const cell = (row) => row.cells[column]?.textContent.trim() ?? "";
    const rows = [...body.rows].sort((a, b) => {
      const x = cell(a), y = cell(b);
      if (!x || !y) return !x - !y;
      const nx = asNumber(x), ny = asNumber(y);
      const order = !isNaN(nx) && !isNaN(ny) ? nx - ny : collator.compare(x, y);
      return descending ? -order : order;
    });
    body.append(...rows);
  }

  // ---------- diagrams: copy and save ----------

  function diagramAt(index) {
    return content.querySelectorAll(".mermaid-block:not(.failed)")[index]?.querySelector("svg") || null;
  }

  function diagramSVG(index) {
    const svg = diagramAt(index);
    if (!svg) return null;
    const copy = svg.cloneNode(true);
    copy.setAttribute("xmlns", "http://www.w3.org/2000/svg");
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + new XMLSerializer().serializeToString(copy);
  }

  // Where the diagram is on the page (not the window), for an image of it.
  function diagramRect(index) {
    const svg = diagramAt(index);
    if (!svg) return null;
    const r = svg.getBoundingClientRect();
    return { x: r.left + window.scrollX, y: r.top + window.scrollY, width: r.width, height: r.height };
  }

  // ---------- link preview ----------

  let linkStatus = null;

  // Where a link goes: the web address, or the file path relative to the document.
  function describeLink(a) {
    const href = a.getAttribute("href");
    if (href.startsWith("#")) return href;
    if (a.protocol === "mailto:") return a.href.slice(7);
    if (a.protocol !== "file:") return a.href;
    const folder = document.baseURI.replace(/[^/]*$/, "");
    let text = a.href.startsWith(folder) ? a.href.slice(folder.length) : a.href.replace(/^file:\/\//, "");
    try { text = decodeURIComponent(text); } catch (_) {}
    return text;
  }

  function showLinkStatus(a) {
    if (!linkStatus) {
      linkStatus = document.createElement("div");
      linkStatus.id = "link-status";
      document.body.append(linkStatus);
    }
    linkStatus.textContent = describeLink(a) + (a.classList.contains("broken") ? " (not found)" : "");
    linkStatus.hidden = false;
  }

  function hideLinkStatus() {
    if (linkStatus) linkStatus.hidden = true;
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
    box.addEventListener("click", closeLightbox);
    document.body.append(box);
    post({ type: "lightbox", open: true });
  }

  function closeLightbox() {
    const box = document.querySelector(".lightbox");
    if (!box) return;
    box.remove();
    post({ type: "lightbox", open: false });
  }

  // ---------- keyboard reading ----------

  // Where each heading starts, for n and p.
  let sourceStops = null;

  function headingStops() {
    if (current.source) {
      sourceStops ??= sourceOffsetsY(headingOffsets(current.md)).map((y) => y - 12);
      return sourceStops;
    }
    // Headings with no layout box (collapsed sections, closed <details>) are skipped.
    return headings().filter((h) => h.getClientRects().length > 0)
      .map((h) => h.getBoundingClientRect().top + window.scrollY - 12);
  }

  function readingKey(e) {
    if (e.metaKey || e.ctrlKey || e.altKey || e.isComposing || !content.firstElementChild) return false;
    if (e.target.closest?.("input, textarea, select, [contenteditable]")) return false;
    const y = window.scrollY;
    switch (e.key) {
      case "j": window.scrollBy({ top: 64, behavior: e.repeat ? "auto" : "smooth" }); break;
      case "k": window.scrollBy({ top: -64, behavior: e.repeat ? "auto" : "smooth" }); break;
      case "g": window.scrollTo(0, 0); break;
      case "G": window.scrollTo(0, document.documentElement.scrollHeight); break;
      case "n": {
        const next = headingStops().find((s) => s > y + 1);
        if (next !== undefined) window.scrollTo(0, next);
        break;
      }
      case "p": {
        const prev = headingStops().filter((s) => s < y - 1).pop();
        window.scrollTo(0, prev ?? 0);
        break;
      }
      default: return false;
    }
    return true;
  }

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeLightbox();
    else if (!document.querySelector(".lightbox") && readingKey(e)) e.preventDefault();
  });

  // ---------- keeping your place between rendered and source view ----------

  let current = { doc: null, source: false, md: "", blocks: null };

  const topHeadings = () => [...content.children].filter((el) => headingLevel(el));

  // Character offset in the Markdown of every top-level heading, in document order.
  // Every Markdown heading in the source: character offset, level and plain text. Cached per text.
  let headingCache = { md: null, list: [] };

  function sourceHeadings(md) {
    if (headingCache.md === md) return headingCache.list;
    const [, body] = splitFrontMatter(md);
    const start = md.length - body.length;
    // marked turns \r\n into \n before measuring; add the \r back to get offsets in `md`.
    const crlf = [];
    for (let i = body.indexOf("\r\n"); i >= 0; i = body.indexOf("\r\n", i + 2)) crlf.push(i - crlf.length);
    const original = (offset) => {
      let lo = 0, hi = crlf.length;
      while (lo < hi) { const mid = (lo + hi) >> 1; if (crlf[mid] < offset) lo = mid + 1; else hi = mid; }
      return start + offset + lo;
    };
    let pos = 0;
    const list = [];
    const scratch = document.createElement("template");
    for (const token of placeLexer.lexer(body)) {
      if (token.type === "heading") {
        scratch.innerHTML = placeLexer.parseInline(token.text);
        list.push({ offset: original(pos), level: token.depth, text: scratch.content.textContent.trim() });
      }
      pos += token.raw.length;
    }
    headingCache = { md, list };
    return list;
  }

  function headingOffsets(md) {
    return sourceHeadings(md).map((h) => h.offset);
  }

  // Character offset in the Markdown of what's at the top of the window (for the editor).
  function placeOffset() {
    if (current.source) return sourceOffsetAtTop() ?? 0;
    const place = readPlace();
    const offset = headingOffsets(current.md)[place.index];
    return offset ?? Math.round(place.ratio * current.md.length);
  }

  // Character offset of an outline entry's heading, or null.
  function headingOffset(id) {
    const offsets = headingOffsets(current.md);
    const m = /^source-(\d+)$/.exec(id);
    if (m) return offsets[Number(m[1])] ?? null;
    const hs = topHeadings();
    const i = hs.findIndex((h) => h.id === id);
    return i >= 0 && hs.length === offsets.length ? offsets[i] : null;
  }

  // Shows the part of the document at a character offset (coming back from the editor).
  function applyOffset(offset) {
    if (current.source) {
      const y = sourceOffsetY(Math.min(offset, Math.max(0, current.md.length - 1)));
      if (y !== null) window.scrollTo(0, Math.max(0, y - 12));
      return;
    }
    let index = -1;
    headingOffsets(current.md).forEach((o, i) => { if (o <= offset) index = i; });
    applyPlace({ index, ratio: offset / Math.max(1, current.md.length) });
  }

  // Keeps the page beside the editor in step with it: the position between two headings in the
  // Markdown maps to the same fraction of the way between them on the page.
  function followOffset(offset) {
    if (current.source) return applyOffset(offset);
    const offsets = headingOffsets(current.md);
    const hs = topHeadings();
    const top = (h) => (h.getClientRects().length ? h.getBoundingClientRect().top + window.scrollY : null);
    let i = -1;
    offsets.forEach((o, k) => { if (o <= offset) i = k; });
    const y0 = i < 0 ? 0 : top(hs[i]);
    const y1 = i + 1 < hs.length ? top(hs[i + 1]) : document.documentElement.scrollHeight;
    if (hs.length !== offsets.length || y0 === null || y1 === null) {
      return window.scrollTo(0, (offset / Math.max(1, current.md.length)) * maxScroll());
    }
    const o0 = i < 0 ? 0 : offsets[i];
    const o1 = i + 1 < offsets.length ? offsets[i + 1] : current.md.length;
    const t = o1 > o0 ? (offset - o0) / (o1 - o0) : 0;
    window.scrollTo(0, Math.max(0, y0 + t * (y1 - y0) - 12));
  }

  const maxScroll = () => Math.max(1, document.documentElement.scrollHeight - window.innerHeight);

  // Where the reader is: the index of the last heading above the top of the window, and the
  // scroll ratio as a fallback.
  function readPlace() {
    const place = { index: -1, ratio: window.scrollY / maxScroll() };
    if (current.source) {
      const offset = sourceOffsetAtTop();
      if (offset !== null) {
        headingOffsets(current.md).forEach((o, i) => { if (o <= offset) place.index = i; });
      }
    } else {
      const hs = topHeadings();
      // Raw HTML headings aren't Markdown headings; the counts then differ, so use the ratio.
      if (hs.length !== headingOffsets(current.md).length) return place;
      hs.forEach((h, i) => {
        if (!h.classList.contains("folded-away") && h.getBoundingClientRect().top <= 12) place.index = i;
      });
    }
    return place;
  }

  function applyPlace(place) {
    if (place.index >= 0) {
      if (current.source) {
        const offset = headingOffsets(current.md)[place.index];
        const y = offset === undefined ? null : sourceOffsetY(offset);
        if (y !== null) return window.scrollTo(0, Math.max(0, y - 12));
      } else {
        const hs = topHeadings();
        // Heading counts differ when raw HTML adds headings; fall back to the ratio then.
        if (hs.length === headingOffsets(current.md).length && hs[place.index]) {
          reveal(hs[place.index]);
          return hs[place.index].scrollIntoView?.({ block: "start" });
        }
      }
    }
    window.scrollTo(0, place.ratio * maxScroll());
  }

  function sourceTextNodes() {
    const code = content.querySelector("pre code");
    if (!code) return [];
    const walker = document.createTreeWalker(code, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    return nodes;
  }

  function sourceOffsetAtTop() {
    const pre = content.querySelector("pre");
    if (!pre || !document.caretRangeFromPoint) return null;
    const rect = pre.getBoundingClientRect();
    const range = document.caretRangeFromPoint(rect.left + 8, Math.max(rect.top, 0) + 8);
    if (!range) return null;
    let offset = 0;
    for (const node of sourceTextNodes()) {
      if (node === range.startContainer) return offset + range.startOffset;
      offset += node.nodeValue.length;
    }
    return null;
  }

  // Page positions of several ascending character offsets, in one pass over the text.
  function sourceOffsetsY(offsets) {
    const ys = [];
    let offset = 0;
    let i = 0;
    for (const node of sourceTextNodes()) {
      const len = node.nodeValue.length;
      while (i < offsets.length && offsets[i] < offset + len) {
        const range = document.createRange();
        range.setStart(node, offsets[i] - offset);
        range.collapse(true);
        const rect = range.getClientRects()[0] || range.getBoundingClientRect();
        if (rect) ys.push(rect.top + window.scrollY);
        i++;
      }
      offset += len;
    }
    return ys;
  }

  function sourceOffsetY(target) {
    let offset = 0;
    for (const node of sourceTextNodes()) {
      const len = node.nodeValue.length;
      if (offset + len > target) {
        const range = document.createRange();
        range.setStart(node, target - offset);
        range.collapse(true);
        const rect = range.getClientRects()[0] || range.getBoundingClientRect();
        return rect ? rect.top + window.scrollY : null;
      }
      offset += len;
    }
    return null;
  }

  // ---------- footnote previews ----------

  let footnoteTip = null;

  function showFootnote(ref) {
    hideFootnote();
    const id = decodeURIComponent((ref.getAttribute("href") || "").slice(1));
    const note = id && document.getElementById(id);
    if (!note) return;
    footnoteTip = document.createElement("div");
    footnoteTip.className = "footnote-tip";
    footnoteTip.innerHTML = note.innerHTML;
    footnoteTip.querySelectorAll("[data-footnote-backref]").forEach((a) => a.remove());
    footnoteTip.querySelectorAll("input").forEach((input) => { input.disabled = true; });
    document.body.append(footnoteTip);
    const r = ref.getBoundingClientRect();
    const width = Math.min(420, window.innerWidth - 32);
    footnoteTip.style.width = width + "px";
    footnoteTip.style.left = Math.max(16, Math.min(r.left - 20, window.innerWidth - width - 16)) + "px";
    footnoteTip.style.top = r.bottom + window.scrollY + 8 + "px";
  }

  function hideFootnote() {
    footnoteTip?.remove();
    footnoteTip = null;
  }

  document.addEventListener("mouseover", (e) => {
    const ref = e.target.closest?.("[data-footnote-ref]");
    if (ref) showFootnote(ref);
    const a = e.target.closest?.("a[href]");
    if (a && content.contains(a)) {
      showLinkStatus(a);
      hoverLink(a);
    }
  });
  document.addEventListener("mouseout", (e) => {
    if (e.target.closest?.("[data-footnote-ref]")) hideFootnote();
    const a = e.target.closest?.("a[href]");
    if (a && !a.contains(e.relatedTarget)) {
      hideLinkStatus();
      leaveLink();
    }
  });

  // ---------- horizontal scrolling hint ----------

  // A two-finger swipe means Back/Forward unless the pointer is over something that scrolls
  // sideways (wide code, tables, math). The app asks the page which one it is.
  let canScrollX = false;
  let pointerQueued = false;
  let pointer = null;

  // Also re-checked after scrolling and rendering, since content can move under a still pointer.
  function checkHorizontalScroll() {
    if (pointerQueued || !pointer) return;
    pointerQueued = true;
    requestAnimationFrame(() => {
      pointerQueued = false;
      const target = document.elementFromPoint?.(pointer.x, pointer.y);
      const el = target?.closest?.("pre, .table-wrap, .math-display, .mermaid-block");
      const can = !!(el && el.scrollWidth > el.clientWidth + 1)
        || document.documentElement.scrollWidth > document.documentElement.clientWidth + 1;
      if (can !== canScrollX) {
        canScrollX = can;
        post({ type: "hscroll", can });
      }
    });
  }

  document.addEventListener("mousemove", (e) => {
    pointer = { x: e.clientX, y: e.clientY };
    checkHorizontalScroll();
  }, { passive: true });

  // ---------- events ----------

  const options = { numbers: false, followEdits: true, smart: false };
  let lastPayload = null;
  document.documentElement.lang = navigator.language || "en";  // for hyphenation

  function setOptions(o) {
    sourceStops = null;  // widths and fonts move the source lines
    if (o.font) document.body.dataset.font = o.font;
    if (o.wrap !== undefined) document.body.classList.toggle("wrap-code", !!o.wrap);
    if (o.lineNumbers !== undefined) document.body.classList.toggle("line-numbers", !!o.lineNumbers);
    if (o.codeLineNumbers !== undefined) document.body.classList.toggle("code-line-numbers", !!o.codeLineNumbers);
    if (o.justify !== undefined) document.body.classList.toggle("justify", !!o.justify);
    if (o.lineHeight !== undefined) document.body.dataset.lineHeight = o.lineHeight;
    if (o.smart !== undefined && !!o.smart !== options.smart) {
      options.smart = !!o.smart;
      // Draw the current document again with the new punctuation, in place.
      if (lastPayload && !lastPayload.source && !lastPayload.clear) {
        window.mdr.render({ ...lastPayload, scroll: -1, sync: false, anchor: "", offset: -1, follow: false });
        post({ type: "rendered" });  // so an open find bar searches again
      }
    }
    if (o.followEdits !== undefined) options.followEdits = !!o.followEdits;
    if (o.numbers !== undefined && !!o.numbers !== options.numbers) {
      options.numbers = !!o.numbers;
      if (content.classList.contains("markdown-body")) {
        numberHeadings();
        current.blocks = null;
        sendOutline();
      }
    }
    if (o.css !== undefined) {
      let style = document.getElementById("user-css");
      if (!style) {
        style = document.createElement("style");
        style.id = "user-css";
        document.head.append(style);
      }
      style.textContent = o.css;
    }
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
    const box = e.target.closest?.("input.task-box");
    if (box) {
      // The app changes [ ] to [x] in the file; the reload then shows the new state.
      // It gets every task's state (before this click) and first word, and only writes if the
      // file's tasks match them one for one.
      const boxes = [...content.querySelectorAll("input.task-box")];
      const tasks = boxes.map((b) => ({
        checked: b === box ? !b.checked : b.checked,
        word: (b.closest("li")?.textContent.match(/[\p{L}\p{N}]+/u) || [""])[0],
      }));
      tickedTask = true;
      setTimeout(() => { tickedTask = false; }, 2000);  // in case no reload follows
      post({ type: "task", index: boxes.indexOf(box), tasks, doc: current.doc });
      return;
    }
    const fold = e.target.closest(".fold");
    if (fold) {
      toggleFold(fold.parentElement, e.altKey);
      return;
    }
    const anchor = e.target.closest(".anchor-link");
    if (anchor) {
      post({ type: "copyLink", id: anchor.parentElement.id });
      return;
    }
    const th = e.target.closest(".markdown-body th.sortable");
    if (th && !e.target.closest("a")) {
      sortTable(th);
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
    // ⌘-click opens in the background.
    post({ type: "link", href: a.href, y: window.scrollY, background: e.metaKey });
  });

  // Tell the app which heading was right-clicked, for "Copy Link to Heading".
  document.addEventListener("contextmenu", (e) => {
    const h = e.target.closest?.(".markdown-body :is(h1, h2, h3, h4, h5, h6)");
    const block = e.target.closest?.(".mermaid-block:not(.failed)");
    const diagram = block?.querySelector("svg")
      ? [...content.querySelectorAll(".mermaid-block:not(.failed)")].indexOf(block) : -1;
    const table = e.target.closest?.(".markdown-body table");
    const math = e.target.closest?.(".math[data-tex]");
    const img = e.target.closest?.(".markdown-body img");
    post({
      type: "context", heading: h && !h.closest(".footnotes") ? h.id : "", diagram,
      table: table ? [...content.querySelectorAll(".markdown-body table")].indexOf(table) : -1,
      tex: math?.dataset.tex || "",
      image: img?.src?.startsWith("file:") ? img.src : "",
    });
  });

  // Words in the selection, for the title bar.
  let selectionTimer = null;
  let selectedWords = 0;
  document.addEventListener("selectionchange", () => {
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(() => {
      const text = String(window.getSelection() || "");
      const words = (text.match(/[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*/gu) || []).length;
      if (words !== selectedWords) {
        selectedWords = words;
        post({ type: "selection", words });
      }
    }, 150);
  });

  let scrollTimer = null;
  window.addEventListener("scroll", () => {
    updateProgress();
    hideFootnote();
    checkHorizontalScroll();
    if (scrollTimer) return;
    scrollTimer = setTimeout(() => {
      scrollTimer = null;
      post({ type: "scroll", y: window.scrollY, progress: Math.min(1, window.scrollY / maxScroll()) });
      updateActive();
    }, 120);
  }, { passive: true });

  window.matchMedia?.("(prefers-color-scheme: dark)").addEventListener?.("change", () => {
    if (content.querySelector(".mermaid-block")) renderDiagrams(content);
  });

  window.addEventListener("resize", () => {
    sourceStops = null;
    updateProgress();
  });

  document.addEventListener("DOMContentLoaded", () => {
    content = document.getElementById("content");
    progressBar = document.createElement("div");
    progressBar.id = "progress";
    progressBar.hidden = true;
    document.body.append(progressBar);
  });

  window.mdr = {
    render: (p) => {
      lastPayload = p;
      return (lastRender = render(p).catch(() => {}));
    },
    setOptions, find, findStep, clearFind, exportHTML, preparePrint, afterPrint, markBroken, showPreview, tableText,
    showOffset: (offset) => followOffset(offset),
    foldAll, diagramSVG, diagramRect, placeOffset, headingOffset,
    scrollToAnchor: (id) => scrollToAnchor(id, true),
    scrollTo: (y) => window.scrollTo(0, y),
    scrollY: () => window.scrollY,
  };
})();
