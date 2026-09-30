import AppKit
import UniformTypeIdentifiers

/// Turns the rendered page into a single self-contained .html file or rich-text clipboard contents.
enum HTMLExport {
    static func document(for page: RenderedPage) -> String {
        let css = (Bundle.main.resourceURL
            .flatMap { try? String(contentsOf: $0.appendingPathComponent("web/style.css"), encoding: .utf8) } ?? "")
            + "\n" + CustomCSS.read()
        let body = inlineImages(page)
        // KaTeX markup needs its stylesheet; it is too heavy to inline with fonts, so link the CDN copy.
        let katex = page.hasMath
            ? "<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/katex@0.18.9/dist/katex.min.css\">\n"
            : ""
        return """
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="generator" content="MDReader">
            <title>\(escape(page.title))</title>
            \(katex)<style>
            \(css)
            </style>
            </head>
            <body data-font="\(Prefs.font.rawValue)"\(UserDefaults.standard.bool(forKey: Prefs.wrapCode) ? " class=\"wrap-code\"" : "")>
            <main id="content" class="markdown-body">
            \(body)
            </main>
            </body>
            </html>

            """
    }

    /// Puts HTML (for Mail, Notes, Pages, Google Docs…), RTF and plain text on the clipboard.
    static func copyRichText(_ page: RenderedPage) {
        let html = "<meta charset=\"utf-8\">" + inlineImages(page)
        // Converting to RTF downloads web images on the main thread, so leave them out of the RTF.
        let offline = html.replacingOccurrences(
            of: #"<img\b[^>]*\bsrc="https?:[^"]*"[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.html, .rtf, .string], owner: nil)
        pb.setString(html, forType: .html)
        if let data = offline.data(using: .utf8),
            let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil),
            let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length))
        {
            pb.setData(rtf, forType: .rtf)
        }
        pb.setString(page.text, forType: .string)
    }

    private static func inlineImages(_ page: RenderedPage) -> String {
        var body = page.html
        for src in Set(page.images) {
            guard let data = dataURI(src) else { continue }
            // innerHTML escapes "&" in attribute values, so match that form too.
            for form in Set([src, src.replacingOccurrences(of: "&", with: "&amp;")]) {
                body = body.replacingOccurrences(of: "src=\"\(form)\"", with: "src=\"\(data)\"")
            }
        }
        return body
    }

    private static func dataURI(_ fileURLString: String) -> String? {
        guard let url = URL(string: fileURLString), url.isFileURL,
            let data = try? Data(contentsOf: url), data.count < 20_000_000
        else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}
