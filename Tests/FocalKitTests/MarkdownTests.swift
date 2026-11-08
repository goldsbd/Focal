import Foundation
import Testing
@testable import FocalKit

@Test func gfmTablesTaskListsAndStrikethroughRender() {
    let html = MarkdownRenderer.body("""
    | Name | Size |
    |------|-----:|
    | a    | 1    |

    - [x] done
    - [ ] todo

    ~~old~~ https://example.com
    """)
    #expect(html.contains("<table>") && html.contains("<th>Name</th>") && html.contains("<td align=\"right\">1</td>"))
    #expect(html.contains("type=\"checkbox\" checked=\"\" disabled=\"\""))
    #expect(html.contains("<del>old</del>"))
    #expect(html.contains("<a href=\"https://example.com\">"))
}

@Test func scriptTagsAreNeutralisedButHarmlessHTMLPasses() {
    let html = MarkdownRenderer.body("<img src=\"a.png\" width=\"40\">\n\n<script>alert(1)</script>\n")
    #expect(html.contains("<img src=\"a.png\" width=\"40\">"))
    #expect(!html.contains("<script>"))
    #expect(html.contains("&lt;script>"))
}

@Test func headingsGetGitHubStyleAnchorsWithRepeatsNumbered() {
    let html = MarkdownRenderer.body("# Getting Started!\n\n## Install & Run `focal`\n\n## Getting Started\n")
    #expect(html.contains("<h1 id=\"getting-started\">Getting Started!</h1>"))
    #expect(html.contains("<h2 id=\"install--run-focal\">"))
    #expect(html.contains("<h2 id=\"getting-started-1\">"))
}

@Test func formatDetection() {
    #expect(TextFormat(typeName: "public.plain-text", url: URL(fileURLWithPath: "/x/notes.md")) == .markdown)
    #expect(TextFormat(typeName: "net.daringfireball.markdown", url: nil) == .markdown)
    #expect(TextFormat(typeName: "public.plain-text", url: URL(fileURLWithPath: "/x/notes.txt")) == .plain)
    #expect(TextFormat(typeName: "public.python-script", url: URL(fileURLWithPath: "/x/a.py")) == .plain)
    #expect(TextFormat(typeName: "public.rtf", url: URL(fileURLWithPath: "/x/a.rtf")) == .rich)
    #expect(TextFormat(typeName: "com.apple.rtfd", url: nil) == .rich)
    #expect(TextFormat(typeName: "public.plain-text", url: nil) == .plain)
}
