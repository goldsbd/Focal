import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Markdown to a styled HTML page, GitHub-flavoured: tables, task lists, strikethrough, autolinks, footnotes.
/// Raw HTML in the Markdown passes through (READMEs use <img>, <details>, <br>) except the tags GFM's
/// tagfilter neutralises (<script>, <iframe>, <style>…); the web view runs no page scripts either way.
public enum MarkdownRenderer {
    public static func body(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_DEFAULT | CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES | CMARK_OPT_VALIDATE_UTF8
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tagfilter", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        markdown.withCString { cmark_parser_feed(parser, $0, markdown.utf8.count) }
        guard let doc = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(doc) }
        guard let html = cmark_render_html(doc, options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(html) }
        return addHeadingAnchors(String(cString: html))
    }

    /// `base`: the Markdown file's folder, so relative images and links resolve from there.
    public static func page(_ markdown: String, base: URL? = nil) -> String {
        let baseTag = base.map { "<base href=\"\($0.absoluteString.replacingOccurrences(of: "\"", with: "%22"))\">" } ?? ""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">\(baseTag)
        <style>\(css)</style></head>
        <body><article class="markdown">\(body(markdown))</article></body></html>
        """
    }

    /// GitHub-style ids on headings ("## Getting Started" → id="getting-started", repeats get -1, -2) so a
    /// README's table of contents links jump within the page.
    static func addHeadingAnchors(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<h([1-6])>(.*?)</h\\1>", options: [.dotMatchesLineSeparators]) else { return html }
        var used: [String: Int] = [:]
        var result = ""
        var last = html.startIndex
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let whole = Range(match.range, in: html), let level = Range(match.range(at: 1), in: html),
                  let inner = Range(match.range(at: 2), in: html) else { continue }
            var slug = slugify(String(html[inner]))
            if let n = used[slug] { used[slug] = n + 1; slug += "-\(n + 1)" } else { used[slug] = 0 }
            result += html[last..<whole.lowerBound]
            result += "<h\(html[level]) id=\"\(slug)\">\(html[inner])</h\(html[level])>"
            last = whole.upperBound
        }
        return result + html[last...]
    }

    static func slugify(_ headingHTML: String) -> String {
        let text = headingHTML.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
        return String(text.lowercased().unicodeScalars.compactMap { s -> Character? in
            if s == " " { return "-" }
            if s == "-" || s == "_" || CharacterSet.alphanumerics.contains(s) { return Character(s) }
            return nil
        })
    }

    // Readable defaults in the spirit of GitHub's rendering; follows the system's light/dark appearance.
    // Sizes are in px at pageZoom 1 (16 px body); the window's text-size zoom scales the whole page.
    static let css = """
    :root { color-scheme: light dark; --fg: #1f2328; --muted: #59636e; --bg: #ffffff; --border: #d1d9e0;
      --soft: #f6f8fa; --code: rgba(129,139,152,.12); --link: #0969da; --mark: #fff8c5; }
    @media (prefers-color-scheme: dark) { :root { --fg: #f0f6fc; --muted: #9198a1; --bg: #0d1117; --border: #3d444d;
      --soft: #151b23; --code: rgba(101,108,118,.2); --link: #4493f8; --mark: rgba(187,128,9,.15); } }
    html { background: var(--bg); }
    body { margin: 0; padding: 28px 36px 48px; color: var(--fg); background: var(--bg);
      font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; word-wrap: break-word; }
    article { max-width: 980px; margin: 0 auto; }
    article > :first-child { margin-top: 0 !important; }
    h1, h2, h3, h4, h5, h6 { margin: 1.5em 0 .6em; font-weight: 600; line-height: 1.25; }
    h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; } h6 { font-size: .85em; color: var(--muted); }
    p, ul, ol, dl, table, pre, blockquote, details { margin: 0 0 1em; }
    a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
    ul, ol { padding-left: 2em; } li + li { margin-top: .25em; } li > p { margin: .5em 0; }
    li:has(> input[type=checkbox]) { list-style: none; } li > input[type=checkbox] { margin: 0 .35em 0 -1.4em; vertical-align: middle; }
    blockquote { margin-left: 0; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
    code, pre, kbd, samp { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 85%; }
    code { padding: .2em .4em; border-radius: 6px; background: var(--code); }
    pre { padding: 16px; overflow: auto; line-height: 1.45; border-radius: 6px; background: var(--soft); }
    pre code { padding: 0; background: none; font-size: 100%; white-space: pre; }
    kbd { padding: .15em .4em; border: 1px solid var(--border); border-bottom-width: 2px; border-radius: 6px; background: var(--soft); }
    hr { height: .25em; margin: 1.5em 0; padding: 0; border: 0; background: var(--border); }
    table { display: block; width: max-content; max-width: 100%; overflow: auto; border-collapse: collapse; }
    th, td { padding: 6px 13px; border: 1px solid var(--border); } th { font-weight: 600; }
    tr:nth-child(2n) { background: var(--soft); }
    img { max-width: 100%; box-sizing: border-box; } mark { background: var(--mark); color: inherit; }
    del { color: var(--muted); } details summary { cursor: pointer; }
    .footnotes { font-size: .875em; color: var(--muted); border-top: 1px solid var(--border); padding-top: 1em; }
    """
}
