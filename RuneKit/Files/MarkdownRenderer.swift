import Foundation

/// Converts Markdown (CommonMark-ish plus GitHub tables, fences, and task lists) into an HTML
/// fragment for the file viewer. Deliberately small: it covers what real READMEs and notes use.
/// Raw HTML blocks (lines starting with a tag) pass through; everything else is escaped.
public enum MarkdownRenderer {
    public static func html(from markdown: String) -> String {
        var ignored: [String]?
        return render(markdown, snippets: &ignored)
    }

    /// Renders and collects runnable shell snippets: each gets a `rune-run:<index>` link, and
    /// `snippets[index]` is the command it stands for.
    public static func renderRunnable(_ markdown: String) -> (html: String, snippets: [String]) {
        var snippets: [String]? = []
        let html = render(markdown, snippets: &snippets)
        return (html, snippets ?? [])
    }

    private static func render(_ markdown: String, snippets: inout [String]?) -> String {
        var out: [String] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []
        var listStack: [(tag: String, indent: Int)] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>" + paragraph.map(inline).joined(separator: "\n") + "</p>")
            paragraph.removeAll()
        }
        func closeLists(to depth: Int = 0) {
            while listStack.count > depth {
                out.append("</li></\(listStack.removeLast().tag)>")
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph(); closeLists()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                let cls = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
                let block = "<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>"
                if snippets != nil, let command = RunnableSnippet.command(from: code.joined(separator: "\n"), language: language) {
                    let index = snippets?.count ?? 0
                    snippets?.append(command)
                    out.append("<div class=\"snippet\"><a class=\"run\" href=\"rune-run:\(index)\" title=\"Put this in your terminal; press Return to run it\">▶ Run…</a>\(block)</div>")
                } else {
                    out.append(block)
                }
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                // A blank line ends a list unless the next line continues it.
                if !listStack.isEmpty {
                    let next = i + 1 < lines.count ? lines[i + 1] : ""
                    if listItem(next) == nil && !next.hasPrefix("  ") { closeLists() }
                }
                i += 1
                continue
            }

            // Raw HTML block.
            if trimmed.hasPrefix("<"), let second = trimmed.dropFirst().first, second.isLetter || second == "/" || second == "!" {
                flushParagraph(); closeLists()
                out.append(line)
                i += 1
                continue
            }

            // Headings.
            if let level = headingLevel(trimmed) {
                flushParagraph(); closeLists()
                let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
                out.append("<h\(level) id=\"\(slug(text))\">\(inline(text))</h\(level)>")
                i += 1
                continue
            }

            // Horizontal rule.
            if isRule(trimmed) {
                flushParagraph(); closeLists()
                out.append("<hr>")
                i += 1
                continue
            }

            // Blockquote (consecutive "> " lines, rendered recursively).
            if trimmed.hasPrefix(">") {
                flushParagraph(); closeLists()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let q = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    quoted.append(q.hasPrefix(" ") ? String(q.dropFirst()) : String(q))
                    i += 1
                }
                out.append("<blockquote>\(render(quoted.joined(separator: "\n"), snippets: &snippets))</blockquote>")
                continue
            }

            // Table: header row followed by a |---| separator.
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph(); closeLists()
                let alignments = tableCells(lines[i + 1]).map(alignment)
                var table = "<table><thead><tr>"
                for (index, cell) in tableCells(line).enumerated() {
                    table += "<th\(alignments.indices.contains(index) ? alignments[index] : "")>\(inline(cell))</th>"
                }
                table += "</tr></thead><tbody>"
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    table += "<tr>"
                    for (index, cell) in tableCells(lines[i]).enumerated() {
                        table += "<td\(alignments.indices.contains(index) ? alignments[index] : "")>\(inline(cell))</td>"
                    }
                    table += "</tr>"
                    i += 1
                }
                out.append(table + "</tbody></table>")
                continue
            }

            // List items (one level of nesting per 2+ spaces of indent).
            if let item = listItem(line) {
                flushParagraph()
                // Each 2 spaces of indent is one level; a list can only go one level deeper.
                let depth = min(item.indent / 2, listStack.count)
                if depth < listStack.count {
                    closeLists(to: depth + 1)
                    if listStack[depth].tag == item.tag {
                        out.append("</li>")
                    } else {
                        closeLists(to: depth)
                    }
                }
                if depth == listStack.count {
                    out.append("<\(item.tag)>")
                    listStack.append((item.tag, item.indent))
                }
                var text = item.text
                var checkbox = ""
                if text.hasPrefix("[ ] ") { checkbox = "<input type=\"checkbox\" disabled> "; text.removeFirst(4) }
                if text.lowercased().hasPrefix("[x] ") { checkbox = "<input type=\"checkbox\" checked disabled> "; text.removeFirst(4) }
                out.append("<li>\(checkbox)\(inline(text))")
                i += 1
                continue
            }

            // Continuation of a list item.
            if !listStack.isEmpty, line.hasPrefix("  ") {
                out.append(" " + inline(trimmed))
                i += 1
                continue
            }

            closeLists()
            paragraph.append(line.hasSuffix("  ") ? trimmed + "<br>" : trimmed)
            i += 1
        }
        flushParagraph()
        closeLists()
        return out.joined(separator: "\n")
    }

    // MARK: Blocks

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.hasPrefix(" ") ? hashes : nil
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func listItem(_ line: String) -> (tag: String, indent: Int, text: String)? {
        let indent = line.prefix(while: { $0 == " " }).count
        let body = line.dropFirst(indent)
        for marker in ["- ", "* ", "+ "] where body.hasPrefix(marker) {
            return ("ul", indent, String(body.dropFirst(2)))
        }
        let digits = body.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 9 {
            let rest = body.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return ("ol", indent, String(rest.dropFirst(2))) }
        }
        return nil
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func alignment(_ separator: String) -> String {
        let left = separator.hasPrefix(":"), right = separator.hasSuffix(":")
        if left && right { return " align=\"center\"" }
        if right { return " align=\"right\"" }
        return ""
    }

    static func slug(_ text: String) -> String {
        text.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : ($0 == " " || $0 == "-" ? "-" : "") }.joined()
    }

    // MARK: Inline

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Inline Markdown: code spans first (protected), then images, links, emphasis.
    static func inline(_ text: String) -> String {
        var codeSpans: [String] = []
        var working = ""
        var chars = Array(text)
        var index = 0
        // Pull out `code` spans so nothing inside them is interpreted.
        while index < chars.count {
            if chars[index] == "`", let close = chars[(index + 1)...].firstIndex(of: "`") {
                codeSpans.append("<code>\(escape(String(chars[(index + 1)..<close])))</code>")
                working += "\u{0}\(codeSpans.count - 1)\u{0}"
                index = close + 1
            } else {
                working.append(chars[index])
                index += 1
            }
        }
        chars = []

        var html = escape(working)
        html = replace(html, pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#, with: "<img src=\"$2\" alt=\"$1\">")
        html = replace(html, pattern: #"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#, with: "<a href=\"$2\">$1</a>")
        html = replace(html, pattern: #"(?<!["=>])\b(https?://[^\s<]+[^\s<.,;:!?)])"#, with: "<a href=\"$1\">$1</a>")
        html = replace(html, pattern: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>")
        html = replace(html, pattern: #"__(.+?)__"#, with: "<strong>$1</strong>")
        html = replace(html, pattern: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, with: "<em>$1</em>")
        html = replace(html, pattern: #"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#, with: "<em>$1</em>")
        html = replace(html, pattern: #"~~(.+?)~~"#, with: "<del>$1</del>")

        for (n, span) in codeSpans.enumerated() {
            html = html.replacingOccurrences(of: "\u{0}\(n)\u{0}", with: span)
        }
        return html
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }
}
