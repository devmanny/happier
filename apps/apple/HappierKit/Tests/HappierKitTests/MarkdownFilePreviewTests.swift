import Foundation
import Testing
@testable import HappierKit

@Suite struct MarkdownFilePreviewTests {
    @Test func recognizesOnlyMarkdownFileExtensionsIgnoringCase() {
        for name in ["report.md", "report.MD", "report.Markdown", "report.MARKDOWN"] {
            #expect(MarkdownFilePreview.supports(URL(fileURLWithPath: "/tmp/" + name)))
        }
        for name in ["report.md.txt", "report.html", "report", "report.pdf"] {
            #expect(!MarkdownFilePreview.supports(URL(fileURLWithPath: "/tmp/" + name)))
        }
    }

    @Test func rendersDocumentBlocksAndInlineFormattingThroughFoundation() {
        let source = """
        # Heading one
        ## Heading two
        ### Heading three
        #### Heading four
        ##### Heading five
        ###### Heading six

        Paragraph with **bold**, *italic* and `inline <code>`.

        - first
        - second
          - nested

        3. third
        4. fourth

        > A quoted **word**.
        """
        let html = MarkdownFilePreview.html(markdown: source, title: "Readable report")
        for level in 1...6 { #expect(html.contains("<h\(level)>Heading")) }
        #expect(html.contains("<p>Paragraph with <strong>bold</strong>, <em>italic</em> and <code>inline &lt;code&gt;</code>.</p>"))
        #expect(html.contains("<ul>"))
        #expect(html.contains("nested"))
        #expect(html.contains("<ol start=\"3\">"))
        #expect(html.contains("<blockquote><p>A quoted <strong>word</strong>.</p></blockquote>"))
        #expect(!html.contains("# Heading"))
    }

    @Test func escapesTitleRawHTMLAndCodeWithoutExecutingOrLosingItsText() {
        let source = """
        <script>alert("bad")</script>

        Raw <img src=x onerror=alert(1)> & text.

        ```html
        <b title="x">literal & code</b>
        ```
        """
        let html = MarkdownFilePreview.html(markdown: source, title: "Report <&> \"name\"")
        #expect(html.contains("<title>Report &lt;&amp;&gt; &quot;name&quot;</title>"))
        #expect(html.contains("&lt;script&gt;alert(&quot;bad&quot;)&lt;/script&gt;"))
        #expect(html.contains("Raw &lt;img src=x onerror=alert(1)&gt; &amp; text."))
        #expect(html.contains("<pre><code>&lt;b title=&quot;x&quot;&gt;literal &amp; code&lt;/b&gt;</code></pre>"))
        #expect(!html.contains("<script"))
        #expect(!html.contains("<img"))
    }

    @Test func onlyWebMailAndFragmentLinksRemainActive() {
        let source = """
        [secure](https://example.com/?a=1&b=2) [web](http://example.com/)
        [mail](mailto:test@example.com) [section](#summary)
        [script](javascript:alert%281%29) [data](data:text/html,hello)
        [relative](../other.md) [local](file:///tmp/other.md)
        """
        let html = MarkdownFilePreview.html(markdown: source, title: "Links")
        #expect(html.contains("href=\"https://example.com/?a=1&amp;b=2\""))
        #expect(html.contains("href=\"http://example.com/\""))
        #expect(html.contains("href=\"mailto:test@example.com\""))
        #expect(html.contains("href=\"#summary\""))
        #expect(!html.contains("href=\"javascript:"))
        #expect(!html.contains("href=\"data:"))
        #expect(!html.contains("href=\"../"))
        #expect(!html.contains("href=\"file:"))
        for label in ["script", "data", "relative", "local"] { #expect(html.contains(label)) }
    }

    @Test func serializesCanonicalTablesWithInlineFormattingAndEscapedCells() {
        let source = "Name | Detail\n--- | ---\n**Manny** | A & B\nWen | <literal>"
        let html = MarkdownFilePreview.html(markdown: source, title: "Table")
        #expect(html.contains("<table>"))
        #expect(html.contains("<th>Name</th>"))
        #expect(html.contains("<td><strong>Manny</strong></td>"))
        #expect(html.contains("<td>A &amp; B</td>"))
        #expect(html.contains("<td>&lt;literal&gt;</td>"))
    }
}
