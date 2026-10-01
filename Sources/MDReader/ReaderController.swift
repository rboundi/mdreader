import AppKit
import UniformTypeIdentifiers
@preconcurrency import WebKit

/// Owns the single WKWebView shared by every tab. Switching tabs just re-renders
/// into the same page, so the app never runs more than one web content process.
@MainActor
final class ReaderController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: ReaderWebView
    /// A Markdown link was followed: file, heading id, and the scroll position being left.
    /// The last value is true for a ⌘-click: open in the background.
    var onOpenFile: ((URL, String?, Double?, Bool) -> Void)?
    /// A task checkbox was clicked: the document's path, the task's index, and every task the page
    /// shows (state before the click, first word).
    var onToggleTask: ((String, Int, [DocTab.ShownTask]) -> Void)?
    /// An in-page link was followed from this scroll position.
    var onNavigate: ((Double) -> Void)?
    /// A zoomed image is showing (Escape closes it rather than leaving focus mode).
    private(set) var lightboxOpen = false
    var onOutline: (([OutlineItem]) -> Void)?
    var onActiveHeading: ((String?) -> Void)?
    var onDisplay: (() -> Void)?
    /// Collapsed section ids for a file, and changes to them.
    var foldsFor: ((URL) -> [String])?
    var onFolds: (([String]) -> Void)?
    /// How far down the page the reader is (0–1), and how many words are selected.
    var onProgress: ((Double) -> Void)?
    /// Whether any open tab has a diagram. When none does, the page is reloaded to drop Mermaid,
    /// which otherwise stays in memory (tens of megabytes) for the rest of the session.
    var diagramsInUse: (() -> Bool)?
    private var mermaidLoaded = false
    var onSelectionWords: ((Int) -> Void)?

    private let templateURL = Bundle.main.resourceURL?.appendingPathComponent("web/index.html")
    private var ready = false
    private var pendingRender: [String: Any]?
    private var lastRender: [String: Any]?
    private var currentKey: String?
    private var scrollPositions: [String: Double] = [:]
    private var appliedFont: ReadingFont?
    private var appliedWidth: ContentWidth?
    private var appliedTheme: String?
    private var appliedFlags: [Bool]?
    private var appliedCSS: String?
    private var appliedLineHeight: String?
    private var customCSS = CustomCSS.read()
    private var cssWatcher: FileWatcher?
    private var printCompletion: ((Bool) -> Void)?
    /// Title for printed and exported copies of the current document.
    private var documentName = ""

    override init() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = ReaderWebView(frame: .zero, configuration: config)
        super.init()

        controller.add(WeakScriptHandler(self), name: "mdr")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.pageZoom = Prefs.zoomLevel

        loadTemplate()
        watchCustomCSS()

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: UserDefaults.didChangeNotification, object: nil)
    }

    /// Picks up changes to custom.css. Does nothing until the file exists.
    func watchCustomCSS() {
        let url = CustomCSS.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            if !customCSS.isEmpty {
                customCSS = ""
                applyOptions()
            }
            return
        }
        guard cssWatcher?.isWatching != true else { return }
        cssWatcher = FileWatcher(url: url) { [weak self] in
            self?.customCSS = CustomCSS.read()
            self?.applyOptions()
        }
        customCSS = CustomCSS.read()
        applyOptions()
    }

    private func loadTemplate() {
        guard let templateURL else { return }
        // Read access to "/" lets relative images next to the Markdown file load.
        webView.loadFileURL(templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    // MARK: Rendering

    func display(_ tab: DocTab?) {
        // A fresh page forgets the libraries it loaded; the render below is queued until it's ready.
        let trim = ready && mermaidLoaded && printCompletion == nil && diagramsInUse?() == false
        if trim {
            mermaidLoaded = false
            ready = false
            lightboxOpen = false
            webView.canScrollHorizontally = false
            loadTemplate()
        }
        guard let tab else {
            currentKey = nil
            send(["clear": true])
            return
        }
        let key = "\(tab.id)|\(tab.showSource)"
        let scroll: Double
        if let pending = tab.pendingScroll {
            scroll = pending
            tab.pendingScroll = nil
        } else if key == currentKey, !trim {
            // Same document + mode: keep the reader where it is (e.g. file changed on disk).
            scroll = -1
        } else {
            scroll = scrollPositions[key] ?? 0
        }
        currentKey = key
        defer { onDisplay?() }
        let anchor = tab.pendingAnchor ?? ""
        tab.pendingAnchor = nil
        let sync = tab.syncOnNextDisplay
        tab.syncOnNextDisplay = false
        documentName = tab.documentName
        let offset = tab.pendingOffset ?? -1
        tab.pendingOffset = nil
        send([
            "path": tab.url.path,
            "folds": foldsFor?(tab.url) ?? [],
            "offset": offset,
            "sync": sync,
            // While editing, the page follows the editor instead of jumping to changes.
            "follow": !tab.editing,
            "anchor": anchor,
            "md": tab.displayText,
            "source": tab.showSource,
            "base": tab.url.deletingLastPathComponent().absoluteString,
            "title": tab.title,
            "error": tab.error ?? "",
            "scroll": scroll,
        ])
    }

    func forget(_ tab: DocTab) {
        scrollPositions["\(tab.id)|true"] = nil
        scrollPositions["\(tab.id)|false"] = nil
    }

    private func send(_ payload: [String: Any]) {
        lastRender = payload
        guard ready else {
            pendingRender = payload
            return
        }
        webView.callAsyncJavaScript(
            "window.mdr.render(payload)", arguments: ["payload": payload], in: nil, in: .page,
            completionHandler: nil)
    }

    /// Last known scroll position of a tab's rendered view.
    func lastScroll(for tab: DocTab) -> Double? {
        scrollPositions["\(tab.id)|false"]
    }

    func scrollTo(_ y: Double) {
        if let key = currentKey { scrollPositions[key] = y }
        webView.callAsyncJavaScript(
            "window.mdr.scrollTo(y)", arguments: ["y": y], in: nil, in: .page, completionHandler: nil)
    }

    func scrollToAnchor(_ id: String) {
        webView.callAsyncJavaScript(
            "window.mdr.scrollToAnchor(id)", arguments: ["id": id], in: nil, in: .page,
            completionHandler: nil)
    }

    func foldAll(_ collapsed: Bool) {
        webView.callAsyncJavaScript(
            "window.mdr.foldAll(c)", arguments: ["c": collapsed], in: nil, in: .page, completionHandler: nil)
    }

    /// Character offset in the Markdown of what's at the top of the page.
    func placeOffset(completion: @escaping (Int) -> Void) {
        webView.callAsyncJavaScript("return window.mdr.placeOffset()", arguments: [:], in: nil, in: .page) {
            result in
            if case .success(let value) = result, let n = value as? NSNumber { completion(n.intValue) } else { completion(0) }
        }
    }

    /// Character offset of an outline heading.
    func headingOffset(_ id: String, completion: @escaping (Int?) -> Void) {
        webView.callAsyncJavaScript("return window.mdr.headingOffset(id)", arguments: ["id": id], in: nil, in: .page) {
            result in
            if case .success(let value) = result, let n = value as? NSNumber { completion(n.intValue) } else { completion(nil) }
        }
    }

    // MARK: Diagrams

    func copyDiagram(_ index: Int) {
        diagramImage(index) { image in
            guard let image else { return NSSound.beep() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }

    func saveDiagram(_ index: Int, asSVG: Bool) {
        let name = "\(documentName.isEmpty ? "Diagram" : documentName) diagram \(index + 1).\(asSVG ? "svg" : "png")"
        let write: (URL) -> Void = { [weak self] url in
            if asSVG {
                self?.webView.callAsyncJavaScript(
                    "return window.mdr.diagramSVG(i)", arguments: ["i": index], in: nil, in: .page
                ) { result in
                    guard case .success(let value) = result, let svg = value as? String else { return NSSound.beep() }
                    try? svg.write(to: url, atomically: true, encoding: .utf8)
                }
            } else {
                self?.diagramImage(index) { image in
                    guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                        let png = rep.representation(using: .png, properties: [:])
                    else { return NSSound.beep() }
                    try? png.write(to: url)
                }
            }
        }
        guard let window = webView.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [asSVG ? .svg : .png]
        panel.nameFieldStringValue = name
        panel.directoryURL = URL(
            fileURLWithPath: UserDefaults.standard.string(forKey: Prefs.pdfFolder) ?? Prefs.defaultPDFFolder)
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { write(url) }
        }
    }

    /// The diagram as shown on the page, at twice its size. Works for diagrams taller than the window.
    private func diagramImage(_ index: Int, completion: @escaping (NSImage?) -> Void) {
        webView.callAsyncJavaScript("return window.mdr.diagramRect(i)", arguments: ["i": index], in: nil, in: .page) {
            [weak self] result in
            guard let self, case .success(let value) = result, let r = value as? [String: Any],
                let x = (r["x"] as? NSNumber)?.doubleValue, let y = (r["y"] as? NSNumber)?.doubleValue,
                let w = (r["width"] as? NSNumber)?.doubleValue, let h = (r["height"] as? NSNumber)?.doubleValue,
                w > 0, h > 0
            else { return completion(nil) }
            let zoom = self.webView.pageZoom
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: x * zoom, y: y * zoom, width: w * zoom, height: h * zoom)
            self.webView.createPDF(configuration: config) { result in
                guard case .success(let data) = result, let pdf = NSPDFImageRep(data: data),
                    let bitmap = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: Int(pdf.bounds.width * 2), pixelsHigh: Int(pdf.bounds.height * 2),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { return completion(nil) }
                bitmap.size = pdf.bounds.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                pdf.draw(in: NSRect(origin: .zero, size: pdf.bounds.size))
                NSGraphicsContext.restoreGraphicsState()
                let image = NSImage(size: pdf.bounds.size)
                image.addRepresentation(bitmap)
                completion(image)
            }
        }
    }

    private func applyOptions() {
        let font = Prefs.font
        let width = Prefs.width
        let theme = Prefs.appearanceMode == .sepia ? "sepia" : ""
        let defaults = UserDefaults.standard
        let flags = [
            Prefs.wrapCode, Prefs.numberHeadings, Prefs.followEdits, Prefs.lineNumbers, Prefs.smartPunctuation,
            Prefs.codeLineNumbers, Prefs.justify,
        ].map(defaults.bool(forKey:))
        let lineHeight = defaults.string(forKey: Prefs.lineHeight) ?? "normal"
        if ready,
            font != appliedFont || width != appliedWidth || theme != appliedTheme || flags != appliedFlags
                || customCSS != appliedCSS || lineHeight != appliedLineHeight
        {
            appliedFont = font
            appliedWidth = width
            appliedTheme = theme
            appliedFlags = flags
            appliedCSS = customCSS
            appliedLineHeight = lineHeight
            let options: [String: Any] = [
                "smart": flags[4], "codeLineNumbers": flags[5], "justify": flags[6], "lineHeight": lineHeight,
                "font": font.rawValue, "width": width.pixels, "theme": theme,
                "wrap": flags[0], "numbers": flags[1], "followEdits": flags[2], "lineNumbers": flags[3],
                "css": customCSS,
            ]
            webView.callAsyncJavaScript(
                "window.mdr.setOptions(o)", arguments: ["o": options], in: nil, in: .page, completionHandler: nil)
        }
        if abs(webView.pageZoom - Prefs.zoomLevel) > 0.001 {
            webView.pageZoom = Prefs.zoomLevel
        }
    }

    @objc private func preferencesChanged() {
        let appearance = Prefs.appearanceMode.nsAppearance
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
        applyOptions()
    }

    // MARK: Find

    /// `scroll` false keeps the reader where it is (searching again after the page re-rendered).
    func find(_ query: String, scroll: Bool = true, index: Int = 0, completion: @escaping (Int, Int) -> Void) {
        callFind("window.mdr.find(q, s, i)", ["q": query, "s": scroll, "i": index], completion)
    }

    func findStep(_ direction: Int, completion: @escaping (Int, Int) -> Void) {
        callFind("window.mdr.findStep(d)", ["d": direction], completion)
    }

    func clearFind() {
        webView.callAsyncJavaScript(
            "window.mdr.clearFind()", arguments: [:], in: nil, in: .page, completionHandler: nil)
    }

    private func callFind(
        _ js: String, _ args: [String: Any], _ completion: @escaping (Int, Int) -> Void
    ) {
        webView.callAsyncJavaScript("return \(js)", arguments: args, in: nil, in: .page) { result in
            guard case .success(let value) = result, let dict = value as? [String: Any] else {
                return completion(0, 0)
            }
            completion(
                (dict["current"] as? NSNumber)?.intValue ?? 0,
                (dict["total"] as? NSNumber)?.intValue ?? 0)
        }
    }

    // MARK: PDF / Print

    /// Renders the current page into a paginated PDF at `url`.
    func exportPDF(to url: URL, completion: @escaping (Bool) -> Void) {
        runPrint(showPanel: false, saveTo: url, completion: completion)
    }

    func printDocument() {
        runPrint(showPanel: true, saveTo: nil) { _ in }
    }

    private func runPrint(showPanel: Bool, saveTo url: URL?, completion: @escaping (Bool) -> Void) {
        guard let window = webView.window, printCompletion == nil else { return completion(false) }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let paper = PaperSize(rawValue: UserDefaults.standard.string(forKey: Prefs.paperSize) ?? "") ?? .system
        info.paperSize = paper.size ?? NSPrintInfo.shared.paperSize
        let margin = (PageMargins(rawValue: UserDefaults.standard.string(forKey: Prefs.margins) ?? "") ?? .normal).points
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        // Title/date header and "Page n of m" footer, drawn by AppKit so links stay clickable.
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] =
            UserDefaults.standard.bool(forKey: Prefs.printHeaderFooter)
        if let url {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        }
        printCompletion = { _ in }  // reserve the print slot while diagrams are prepared
        webView.callAsyncJavaScript("await window.mdr.preparePrint()", arguments: [:], in: nil, in: .page) {
            [weak self] _ in
            self?.startPrint(info: info, window: window, showPanel: showPanel, saveTo: url, completion: completion)
        }
    }

    private func startPrint(
        info: NSPrintInfo, window: NSWindow, showPanel: Bool, saveTo url: URL?,
        completion: @escaping (Bool) -> Void
    ) {
        let op = webView.printOperation(with: info)
        op.showsPrintPanel = showPanel
        op.showsProgressPanel = false
        // Shown in the PDF header: the document's name, not the (possibly de-duplicated) file name.
        op.jobTitle = documentName.isEmpty
            ? (url?.deletingPathExtension().lastPathComponent ?? "Document") : documentName
        // WKWebView's print view needs a real frame, otherwise pages come out blank.
        op.view?.frame = webView.bounds
        // Printing lays the page out again and leaves it scrolled; put the reader back afterwards.
        let savedScroll = currentKey.flatMap { scrollPositions[$0] } ?? 0
        printCompletion = { [weak self] success in
            self?.webView.callAsyncJavaScript(
                "window.scrollTo(0, y); await window.mdr.afterPrint()", arguments: ["y": savedScroll],
                in: nil, in: .page, completionHandler: nil)
            completion(success)
        }
        op.runModal(
            for: window, delegate: self,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printOperationDidRun(
        _ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        let completion = printCompletion
        printCompletion = nil
        completion?(success)
    }

    // MARK: HTML export

    /// The rendered page as standalone HTML (images inlined, reader chrome removed).
    /// `plain` simplifies what Word and RTF can't hold (checkboxes, math markup, diagrams).
    func renderedHTML(plain: Bool = false, completion: @escaping (RenderedPage?) -> Void) {
        webView.callAsyncJavaScript("return await window.mdr.exportHTML(p)", arguments: ["p": plain], in: nil, in: .page) {
            result in
            guard case .success(let value) = result, let dict = value as? [String: Any],
                let html = dict["html"] as? String
            else { return completion(nil) }
            completion(
                RenderedPage(
                    html: html,
                    text: dict["text"] as? String ?? "",
                    title: dict["title"] as? String ?? "",
                    images: (dict["images"] as? [String]) ?? [],
                    hasMath: (dict["hasMath"] as? Bool) ?? false))
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        appliedFont = nil
        appliedWidth = nil
        appliedTheme = nil
        appliedFlags = nil
        appliedCSS = nil
        appliedLineHeight = nil
        applyOptions()
        if let payload = pendingRender {
            pendingRender = nil
            send(payload)
            // An open find bar searches the page again now that it's there.
            onDisplay?()
        }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Only the bundled template may load in the view; everything else is handled natively.
        if action.request.url?.standardizedFileURL == templateURL?.standardizedFileURL,
            action.navigationType != .linkActivated
        {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        if action.navigationType == .linkActivated, let url = action.request.url {
            handleLink(url)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // WebKit's page process crashed or was killed: reload the template and redraw the current tab.
        ready = false
        mermaidLoaded = false
        lightboxOpen = false
        self.webView.canScrollHorizontally = false
        pendingRender = lastRender
        loadTemplate()
    }

    // MARK: WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            return
        }
        switch type {
        case "scroll":
            if let key = currentKey, let y = body["y"] as? NSNumber {
                scrollPositions[key] = y.doubleValue
            }
            if let progress = body["progress"] as? NSNumber { onProgress?(progress.doubleValue) }
        case "rendered":
            onDisplay?()
        case "library":
            if body["name"] as? String == "mermaid" { mermaidLoaded = true }
        case "selection":
            onSelectionWords?((body["words"] as? NSNumber)?.intValue ?? 0)
        case "copyLink":
            if let id = body["id"] as? String, !id.isEmpty { webView.onCopyHeadingLink?(id) }
        case "preview":
            if let href = body["href"] as? String, let seq = body["seq"] as? NSNumber { preview(href, seq: seq.intValue) }
        case "outline":
            let items = (body["items"] as? [[String: Any]] ?? []).compactMap { item -> OutlineItem? in
                guard let id = item["id"] as? String, let text = item["text"] as? String,
                    let level = (item["level"] as? NSNumber)?.intValue
                else { return nil }
                return OutlineItem(id: id, level: level, text: text)
            }
            onOutline?(items)
        case "active":
            let id = body["id"] as? String
            onActiveHeading?(id?.isEmpty == false ? id : nil)
        case "link":
            if let href = body["href"] as? String, let url = URL(string: href) {
                handleLink(url, from: (body["y"] as? NSNumber)?.doubleValue, background: body["background"] as? Bool ?? false)
            }
        case "task":
            if let index = (body["index"] as? NSNumber)?.intValue, let items = body["tasks"] as? [[String: Any]] {
                let shown = items.map {
                    DocTab.ShownTask(checked: $0["checked"] as? Bool ?? false, word: $0["word"] as? String ?? "")
                }
                onToggleTask?(body["doc"] as? String ?? "", index, shown)
            }
        case "anchor":
            if let y = body["y"] as? NSNumber { onNavigate?(y.doubleValue) }
        case "hscroll":
            webView.canScrollHorizontally = (body["can"] as? Bool) ?? false
        case "lightbox":
            lightboxOpen = (body["open"] as? Bool) ?? false
        case "context":
            webView.contextHeading = body["heading"] as? String ?? ""
            webView.contextDiagram = (body["diagram"] as? NSNumber)?.intValue ?? -1
            webView.contextTable = (body["table"] as? NSNumber)?.intValue ?? -1
            webView.contextTeX = body["tex"] as? String ?? ""
            webView.contextImage = (body["image"] as? String).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
        case "folds":
            onFolds?(body["ids"] as? [String] ?? [])
        case "links":
            if let token = body["token"] as? NSNumber, let files = body["files"] as? [String] {
                checkLinks(files, token: token.intValue)
            }
        case "copy":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default:
            break
        }
    }

    /// Reads a linked note for the hover preview.
    private func preview(_ href: String, seq: Int) {
        guard var parts = URLComponents(string: href) else { return }
        parts.fragment = nil
        parts.query = nil
        guard let url = parts.url, url.isFileURL else { return }
        Task {
            let text = await Task.detached(priority: .userInitiated) { () -> String? in
                guard MarkdownFiles.canOpen(url), let file = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? file.close() }
                // The preview shows the start of a note or one section; a megabyte is plenty.
                return String(decoding: (try? file.read(upToCount: 1_000_000)) ?? Data(), as: UTF8.self)
            }.value
            guard let text else { return }
            webView.callAsyncJavaScript(
                "window.mdr.showPreview(s, md)", arguments: ["s": seq, "md": text], in: nil, in: .page,
                completionHandler: nil)
        }
    }

    /// A table from the page as tab-separated text (pastes as cells) or CSV.
    func copyTable(_ index: Int, csv: Bool) {
        webView.callAsyncJavaScript("return window.mdr.tableText(i, c)", arguments: ["i": index, "c": csv], in: nil, in: .page) {
            result in
            guard case .success(let value) = result, let text = value as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Scrolls the page to the part of the Markdown at `offset` (following the editor).
    func showOffset(_ offset: Int) {
        webView.callAsyncJavaScript(
            "window.mdr.showOffset(o)", arguments: ["o": offset], in: nil, in: .page, completionHandler: nil)
    }

    /// Tells the page which of its links to local files point at nothing.
    private func checkLinks(_ files: [String], token: Int) {
        Task {
            let missing = await Task.detached(priority: .userInitiated) {
                files.filter { href in
                    guard let url = URL(string: href), url.isFileURL else { return false }
                    return !FileManager.default.fileExists(atPath: url.path)
                }
            }.value
            guard !missing.isEmpty else { return }
            webView.callAsyncJavaScript(
                "window.mdr.markBroken(t, m)", arguments: ["t": token, "m": missing], in: nil, in: .page,
                completionHandler: nil)
        }
    }

    private func handleLink(_ url: URL, from y: Double? = nil, background: Bool = false) {
        if url.isFileURL {
            var clean = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let fragment = clean?.fragment
            clean?.fragment = nil
            clean?.query = nil
            guard let fileURL = clean?.url else { return }
            if MarkdownFiles.isMarkdown(fileURL) {
                onOpenFile?(fileURL, fragment, y, background)
            } else if !FileManager.default.fileExists(atPath: fileURL.path) {
                NSSound.beep()
            } else if MarkdownFiles.isSafeToOpen(fileURL) {
                NSWorkspace.shared.open(fileURL)
            } else {
                // Never launch apps or scripts from a document link; show them in Finder instead.
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        } else if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = !background
            NSWorkspace.shared.open(url, configuration: configuration)
        }
    }
}

struct OutlineItem: Identifiable, Equatable {
    let id: String
    let level: Int
    let text: String
}

struct RenderedPage {
    let html: String
    let text: String
    let title: String
    let images: [String]
    let hasMath: Bool
}

/// Breaks the retain cycle between WKUserContentController and its handler.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

enum MarkdownFiles {
    static let extensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtext", "mdtxt", "text", "txt",
    ]
    static func isMarkdown(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Markdown proper, for the Files sidebar (leaves out .txt and .text).
    static func isMarkdownDocument(_ url: URL) -> Bool {
        isMarkdown(url) && !["txt", "text"].contains(url.pathExtension.lowercased())
    }

    static let maxFileSize = 20 * 1024 * 1024

    /// One URL per file: letter case as on disk, symlinks resolved, no /private prefix. Keeps a
    /// file from opening in two tabs when it's reached by different spellings.
    static func canonical(_ url: URL) -> URL {
        guard let path = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath else {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath).standardizedFileURL
    }

    static func isTooLarge(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > maxFileSize
    }

    /// Markdown or any other plain-text file (README, LICENSE, .rst…) up to 20 MB.
    static func canOpen(_ link: URL) -> Bool {
        // Check the file a symlink points to, not the link itself.
        let url = link.resolvingSymlinksInPath()
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, (values.fileSize ?? 0) <= maxFileSize
        else { return false }
        if !isMarkdown(url), contentType(url)?.conforms(to: .text) != true, !url.pathExtension.isEmpty {
            return false
        }
        return !looksBinary(url)
    }

    /// A NUL byte in the first 8 KB means it's not text (catches extension-less binaries).
    private static func looksBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        // UTF-16 text legitimately contains NULs; it starts with a byte-order mark.
        if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return false }
        return head.contains(0)
    }

    /// Documents a link may open in their default app. Apps, scripts, installers, web pages,
    /// SVGs and configuration profiles are shown in Finder instead.
    static func isSafeToOpen(_ url: URL) -> Bool {
        guard let type = contentType(url) else { return false }
        let risky: [UTType] = [
            .application, .executable, .script, .shellScript, .package, .bundle, .html, .svg, .xml,
        ]
        if risky.contains(where: { type.conforms(to: $0) }) { return false }
        let safe: [UTType] = [.image, .pdf, .plainText, .audiovisualContent, .presentation, .spreadsheet]
        return safe.contains(where: { type.conforms(to: $0) })
    }

    private static func contentType(_ url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
    }
}

/// WKWebView that accepts dropped files as new tabs and trims browser-only context menu items.
final class ReaderWebView: WKWebView {
    var onDropFiles: (([URL]) -> Void)?
    var onCopyHeadingLink: ((String) -> Void)?
    /// Back (-1) or Forward (+1) from a trackpad swipe, and which of them is possible right now.
    var onSwipe: ((Int) -> Void)?
    var swipeDirections: (() -> (back: Bool, forward: Bool))?
    /// Reported by the page: the pointer is over something that scrolls sideways.
    var canScrollHorizontally = false
    /// Id of the heading under the last right-click, reported by the page just before the menu opens.
    var contextHeading = ""
    /// Index of the diagram under the last right-click, or -1.
    var contextDiagram = -1
    var contextTable = -1
    var contextTeX = ""
    var contextImage: URL?
    var onCopyDiagram: ((Int) -> Void)?
    var onCopyTable: ((Int, Bool) -> Void)?
    var onSaveDiagram: ((Int, Bool) -> Void)?

    private static let hiddenMenuItems = [
        "Reload", "GoBack", "GoForward", "OpenLink", "OpenImage", "DownloadLinked", "DownloadImage",
        "OpenFrame", "InspectElement",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.items.removeAll { item in
            let id = item.identifier?.rawValue ?? ""
            return Self.hiddenMenuItems.contains { id.contains($0) }
        }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        if !contextHeading.isEmpty {
            let item = NSMenuItem(title: "Copy Link to Heading", action: #selector(copyHeadingLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = contextHeading
            menu.insertItem(item, at: 0)
            if menu.items.count > 1 { menu.insertItem(.separator(), at: 1) }
        }
        if contextDiagram >= 0 {
            let items = [
                NSMenuItem(title: "Copy Diagram", action: #selector(copyDiagram(_:)), keyEquivalent: ""),
                NSMenuItem(title: "Save Diagram as PNG…", action: #selector(saveDiagramPNG(_:)), keyEquivalent: ""),
                NSMenuItem(title: "Save Diagram as SVG…", action: #selector(saveDiagramSVG(_:)), keyEquivalent: ""),
            ]
            if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
            for item in items.reversed() {
                item.target = self
                item.tag = contextDiagram
                menu.insertItem(item, at: 0)
            }
        }
        var extra: [NSMenuItem] = []
        if contextTable >= 0 {
            extra.append(item("Copy Table", #selector(copyTable(_:)), tag: contextTable))
            extra.append(item("Copy Table as CSV", #selector(copyTableCSV(_:)), tag: contextTable))
        }
        if !contextTeX.isEmpty {
            extra.append(item("Copy LaTeX", #selector(copyTeX(_:)), object: contextTeX))
        }
        if let image = contextImage {
            extra.append(item("Open Image in Preview", #selector(openImage(_:)), object: image))
            extra.append(item("Show Image in Finder", #selector(revealImage(_:)), object: image))
        }
        if !extra.isEmpty {
            if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
            extra.reversed().forEach { menu.insertItem($0, at: 0) }
        }
        contextHeading = ""
        contextDiagram = -1
        contextTable = -1
        contextTeX = ""
        contextImage = nil
        super.willOpenMenu(menu, with: event)
    }

    private func item(_ title: String, _ action: Selector, tag: Int = 0, object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.representedObject = object
        return item
    }

    @objc private func copyTable(_ sender: NSMenuItem) { onCopyTable?(sender.tag, false) }
    @objc private func copyTableCSV(_ sender: NSMenuItem) { onCopyTable?(sender.tag, true) }

    @objc private func copyTeX(_ sender: NSMenuItem) {
        guard let tex = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tex, forType: .string)
    }

    @objc private func openImage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func revealImage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyDiagram(_ sender: NSMenuItem) { onCopyDiagram?(sender.tag) }
    @objc private func saveDiagramPNG(_ sender: NSMenuItem) { onSaveDiagram?(sender.tag, false) }
    @objc private func saveDiagramSVG(_ sender: NSMenuItem) { onSaveDiagram?(sender.tag, true) }

    @objc private func copyHeadingLink(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onCopyHeadingLink?(id) }
    }

    // Two-finger horizontal swipe = Back/Forward, as in Safari, unless the pointer is over wide
    // content that scrolls sideways. Follows the "Swipe between pages" trackpad setting.
    override func scrollWheel(with event: NSEvent) {
        guard event.phase == .began, !canScrollHorizontally, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
            abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5,
            let directions = swipeDirections?(), directions.back || directions.forward
        else { return super.scrollWheel(with: event) }
        var handled = false
        event.trackSwipeEvent(
            options: [.lockDirection, .clampGestureAmount],
            dampenAmountThresholdMin: directions.forward ? -1 : 0,
            max: directions.back ? 1 : 0
        ) { [weak self] amount, _, isComplete, _ in
            guard isComplete, !handled, abs(amount) >= 1 else { return }
            handled = true
            self?.onSwipe?(amount > 0 ? -1 : 1)
        }
    }

    // Three-finger swipes, when the trackpad is set up that way.
    override func swipe(with event: NSEvent) {
        if event.deltaX < 0 { onSwipe?(-1) } else if event.deltaX > 0 { onSwipe?(1) } else { super.swipe(with: event) }
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}
