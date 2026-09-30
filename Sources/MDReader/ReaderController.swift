import AppKit
import UniformTypeIdentifiers
@preconcurrency import WebKit

/// Owns the single WKWebView shared by every tab. Switching tabs just re-renders
/// into the same page, so the app never runs more than one web content process.
@MainActor
final class ReaderController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: ReaderWebView
    var onOpenFile: ((URL, String?) -> Void)?
    var onOutline: (([OutlineItem]) -> Void)?
    var onActiveHeading: ((String?) -> Void)?
    var onDisplay: (() -> Void)?

    private let templateURL = Bundle.main.resourceURL?.appendingPathComponent("web/index.html")
    private var ready = false
    private var pendingRender: [String: Any]?
    private var lastRender: [String: Any]?
    private var currentKey: String?
    private var scrollPositions: [String: Double] = [:]
    private var appliedFont: ReadingFont?
    private var appliedWidth: ContentWidth?
    private var printCompletion: ((Bool) -> Void)?

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

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: UserDefaults.didChangeNotification, object: nil)
    }

    private func loadTemplate() {
        guard let templateURL else { return }
        // Read access to "/" lets relative images next to the Markdown file load.
        webView.loadFileURL(templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    // MARK: Rendering

    func display(_ tab: DocTab?) {
        guard let tab else {
            currentKey = nil
            send(["clear": true])
            return
        }
        let key = "\(tab.id)|\(tab.showSource)"
        // Same document + mode: keep the reader where it is (e.g. file changed on disk).
        let scroll: Double = key == currentKey ? -1 : (scrollPositions[key] ?? 0)
        currentKey = key
        defer { onDisplay?() }
        let anchor = tab.pendingAnchor ?? ""
        tab.pendingAnchor = nil
        send([
            "anchor": anchor,
            "md": tab.text,
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

    func scrollToAnchor(_ id: String) {
        webView.callAsyncJavaScript(
            "window.mdr.scrollToAnchor(id)", arguments: ["id": id], in: nil, in: .page,
            completionHandler: nil)
    }

    private func applyOptions() {
        let font = Prefs.font
        let width = Prefs.width
        if ready, font != appliedFont || width != appliedWidth {
            appliedFont = font
            appliedWidth = width
            webView.callAsyncJavaScript(
                "window.mdr.setOptions(o)",
                arguments: ["o": ["font": font.rawValue, "width": width.pixels]], in: nil,
                in: .page, completionHandler: nil)
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

    func find(_ query: String, completion: @escaping (Int, Int) -> Void) {
        callFind("window.mdr.find(q)", ["q": query], completion)
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
        info.paperSize = NSPrintInfo.shared.paperSize
        info.topMargin = 42
        info.bottomMargin = 42
        info.leftMargin = 42
        info.rightMargin = 42
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
        let title = ((webView.title ?? "") as NSString).deletingPathExtension
        op.jobTitle = title.isEmpty ? (url?.deletingPathExtension().lastPathComponent ?? "Document") : title
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
    func renderedHTML(completion: @escaping (RenderedPage?) -> Void) {
        webView.callAsyncJavaScript("return await window.mdr.exportHTML()", arguments: [:], in: nil, in: .page) {
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
        applyOptions()
        if let payload = pendingRender {
            pendingRender = nil
            send(payload)
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
                handleLink(url)
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

    private func handleLink(_ url: URL) {
        if url.isFileURL {
            var clean = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let fragment = clean?.fragment
            clean?.fragment = nil
            clean?.query = nil
            guard let fileURL = clean?.url else { return }
            if MarkdownFiles.isMarkdown(fileURL) {
                onOpenFile?(fileURL, fragment)
            } else if !FileManager.default.fileExists(atPath: fileURL.path) {
                NSSound.beep()
            } else if MarkdownFiles.isSafeToOpen(fileURL) {
                NSWorkspace.shared.open(fileURL)
            } else {
                // Never launch apps or scripts from a document link; show them in Finder instead.
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        } else if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
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

    static let maxFileSize = 20 * 1024 * 1024

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
        super.willOpenMenu(menu, with: event)
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
