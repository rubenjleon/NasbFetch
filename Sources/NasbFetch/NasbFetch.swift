// NasbFetch.swift
// Fetches scripture passages from nasb.literalword.com and prints clean,
// text-message-ready output (headings + verses, no nav links, no footer).
//
// Usage:
//   nasb "Hebrews 6:13-7:28"        copy rich text to clipboard (default)
//   nasb -p "Hebrews 6:13-7:28"     print styled passage in the terminal
//   nasb "..." | pbcopy              piped: plain text, clipboard untouched
//   nasb -h                          show help
//
// The quotes are required: semicolons are shell command separators.
//
// Behavior summary:
//   - Default (interactive terminal): builds styled HTML (serif font,
//     bold title, superscript verse numbers, true italics/small-caps,
//     indented poetry, bold-italic section headings) and puts it on the
//     clipboard via NSPasteboard with a plain-text fallback. Paste into
//     Messages/Notes/Mail. Messages strips CSS margins and font sizes,
//     so titles/subheads carry explicit <b>/<i> and gaps are explicit
//     <br> content.
//   - -p / --print: ANSI-styled terminal view — bold headings, dim verse
//     numbers, italics for supplied words, UPPERCASE small-caps,
//     indented poetry. Clipboard untouched.
//   - stdout is a pipe or file: plain flowed text, no escape codes, no
//     clipboard side effects (safe for scripts and cron).
//
// Adjacent passages merge under one heading: the site renders a query
// like "Exodus 3:15,16" as two separate passages; when one passage
// directly continues the previous (same book/chapter, next verse) they
// are combined and the heading rebuilt ("Exodus 3:15,16" / "3:15-17").
//
// Parsing is keyed to the site's real markup (verified June 2026):
//   <p class="Passage__StyledPassageTitle...">Hebrews 6:13-7:28</p>
//   <span class="verse" data-key=58-007-001>
//     <small data-verse=1><span>1 </span></small>
//     <span class="prose">...verse text...</span>
//   </span>
// data-key is BOOK-CHAPTER-VERSE, which lets us label verses with
// chapter:verse when a passage spans more than one chapter.
// MAINTENANCE: if the site redesigns, re-capture a page with
//   curl -s -A "Mozilla/5.0" "https://nasb.literalword.com/?q=John+3:16" -o page.html
// and re-verify the StyledPassageTitle / span.verse / data-key selectors.

import Foundation
import AppKit
import SwiftSoup

/// Minimal interface both renderers' verse types share, so section
/// merging can be written once.
protocol VerseRef {
    var book: Int { get }
    var chapter: Int { get }
    var verse: Int { get }
}

@main
struct NasbFetch {

    // ANSI escape codes (used only when stdout is a terminal)
    enum Ansi {
        static let reset     = "\u{1B}[0m"
        static let bold      = "\u{1B}[1m"
        static let dim       = "\u{1B}[2m"
        static let italicOn  = "\u{1B}[3m"
        static let italicOff = "\u{1B}[23m"
    }

    static let helpText = """
        nasb — fetch NASB scripture from nasb.literalword.com

        usage:
          nasb "Exodus 2:24; 3:15,16; 6:8; 32:13"
                Copy the passages to the clipboard as rich text.
                Paste into Messages, Notes, or Mail.

          nasb -p "Hebrews 6:13-7:28"
                Print the passages in the terminal instead (styled).
                The clipboard is not touched.

          nasb "John 3:16" > file.txt     (or  | pbcopy, etc.)
                When output is piped or redirected, plain text is
                written and the clipboard is not touched.

        options:
          -p, --print   print to terminal instead of copying
          -c, --copy    copy to clipboard (this is already the default)
          -h, --help    show this help

        notes:
          Quotes around the reference are required — semicolons
          separate shell commands.
          References use the site's syntax: "Exodus 2:24; 3:15,16",
          "Hebrews 6:13-7:28", "Psalm 23", etc.
        """

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())

        if args.contains("-h") || args.contains("--help") {
            print(helpText)
            exit(0)
        }

        let printMode = args.contains("-p") || args.contains("--print")
        args.removeAll { ["-p", "--print", "-c", "--copy"].contains($0) }

        guard !args.isEmpty else {
            err(helpText)
            exit(1)
        }

        // Join in case the user forgot quotes around a space-only query.
        let query = args.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Percent-encode EVERYTHING except unreserved characters, then use
        // '+' for spaces (the site's own convention). Critically, this
        // encodes ';' as %3B — a raw semicolon gets treated as a query
        // terminator and everything after your first reference is dropped.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            err("error: could not URL-encode query")
            exit(1)
        }
        let q = encoded.replacingOccurrences(of: "%20", with: "+")

        guard let url = URL(string: "https://nasb.literalword.com/?q=\(q)") else {
            err("error: could not build URL")
            exit(1)
        }

        do {
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )

            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                err("error: HTTP \(http.statusCode) from \(url.host ?? "server")")
                exit(1)
            }
            guard let html = String(data: data, encoding: .utf8) else {
                err("error: response was not valid UTF-8")
                exit(1)
            }

            let interactive = isatty(STDOUT_FILENO) == 1

            if printMode || !interactive {
                // Print to stdout: styled when a human is looking,
                // plain when piped/redirected. No clipboard side effects.
                let passages = try extractPassages(from: html,
                                                   pretty: interactive)
                guard !passages.isEmpty else {
                    err("warning: no passages found — check the reference, or the site layout may have changed")
                    exit(1)
                }
                print(passages)
            } else {
                // Default: copy rich text to the clipboard.
                let richHtml = try buildClipboardHTML(from: html)
                let plain = try extractPassages(from: html, pretty: false)
                guard !plain.isEmpty else {
                    err("warning: no passages found — check the reference, or the site layout may have changed")
                    exit(1)
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.declareTypes([.html, .string], owner: nil)
                pb.setString(richHtml, forType: .html)
                pb.setString(plain, forType: .string)
                print("Copied \(query) to clipboard — paste into Messages, Notes, or Mail. (nasb -h for help)")
            }
        } catch {
            err("error: \(error.localizedDescription)")
            exit(1)
        }
    }

    // MARK: - Section merging

    /// Merges a section into the previous one when it directly continues
    /// it: same book, same chapter, very next verse. The merged heading is
    /// rebuilt as "Book ch:v,v" with consecutive runs collapsed (15,16 for
    /// pairs, 15-17 for longer runs). Cross-chapter sections never merge.
    static func mergeAdjacentSections<V: VerseRef>(
        _ sections: [(title: String, verses: [V])]
    ) -> [(title: String, verses: [V])] {
        var merged: [(title: String, verses: [V])] = []

        for section in sections {
            if let prev = merged.last,
               let prevLast = prev.verses.last,
               let first = section.verses.first,
               Set(prev.verses.map { $0.chapter }).count == 1,
               Set(section.verses.map { $0.chapter }).count == 1,
               first.book == prevLast.book,
               first.chapter == prevLast.chapter,
               first.verse == prevLast.verse + 1 {

                let idx = merged.count - 1
                merged[idx].verses.append(contentsOf: section.verses)

                // Rebuild the heading. The book name is the previous title
                // minus its final reference token, which stays valid even
                // after earlier merges ("Exodus 3:15,16" -> "Exodus").
                let bookName = merged[idx].title
                    .split(separator: " ").dropLast().joined(separator: " ")
                if !bookName.isEmpty {
                    let ch = merged[idx].verses[0].chapter
                    let runs = collapseVerseRuns(merged[idx].verses.map { $0.verse })
                    merged[idx].title = "\(bookName) \(ch):\(runs)"
                }
            } else {
                merged.append(section)
            }
        }
        return merged
    }

    /// [15,16] -> "15,16"   [15,16,17] -> "15-17"   [3,5,6] -> "3,5,6"
    static func collapseVerseRuns(_ verses: [Int]) -> String {
        var parts: [String] = []
        var i = 0
        while i < verses.count {
            var j = i
            while j + 1 < verses.count && verses[j + 1] == verses[j] + 1 { j += 1 }
            if j == i {
                parts.append("\(verses[i])")
            } else if j == i + 1 {
                parts.append("\(verses[i]),\(verses[j])")
            } else {
                parts.append("\(verses[i])-\(verses[j])")
            }
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    // MARK: - Plain / ANSI rendering

    /// Walks passage titles and verse spans in document order, so multiple
    /// passages (semicolon-separated queries) come out grouped under their
    /// own headings.
    static func extractPassages(from html: String, pretty: Bool) throws -> String {
        let doc = try SwiftSoup.parse(html)

        if pretty {
            // Small-caps quotations (OT citations, LORD) -> UPPERCASE,
            // like a printed NASB.
            for sc in try doc.select("span.small-caps").array() {
                try sc.text(sc.text().uppercased())
            }
            // Supplied words (site renders in italics) -> ANSI italics.
            // prepend/append (not text setter) so internal spacing survives.
            for i in try doc.select("span.verse i").array() {
                try i.prepend(Ansi.italicOn)
                try i.append(Ansi.italicOff)
            }
            // Poetry lines -> own line, indented. The "\n" survives
            // SwiftSoup's whitespace normalization; INDENT is swapped for
            // real spaces after text extraction.
            for p in try doc.select("div.poetry").array() {
                try p.prepend("\\n@INDENT@")
            }
        }

        struct VerseItem: VerseRef {
            let book: Int
            let chapter: Int
            let verse: Int
            let text: String
        }
        var sections: [(title: String, verses: [VerseItem])] = []

        for el in try doc.select("[class*=StyledPassageTitle], span.verse").array() {
            if el.hasClass("verse") {
                // data-key looks like "58-007-001" -> book-chapter-verse
                let parts = try el.attr("data-key").split(separator: "-")
                let book    = parts.count == 3 ? Int(parts[0]) ?? 0 : 0
                let chapter = parts.count == 3 ? Int(parts[1]) ?? 0 : 0
                let verse   = parts.count == 3 ? Int(parts[2]) ?? 0 : 0

                // Strip the section subhead (h3), the drop-cap chapter
                // numeral (h2), and the site's own verse number (small) --
                // we re-label below so chapter starts get numbers too.
                try el.select("h2, h3, small").remove()
                var text = try el.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if pretty {
                    text = text
                        .replacingOccurrences(of: "\\n", with: "\n")
                        .replacingOccurrences(of: "@INDENT@ ", with: "        ")
                        .replacingOccurrences(of: "@INDENT@", with: "        ")
                }
                guard !text.isEmpty else { continue }

                if sections.isEmpty { sections.append(("", [])) }
                sections[sections.count - 1].verses.append(VerseItem(
                    book: book, chapter: chapter, verse: verse, text: text))
            } else {
                sections.append((try el.text().trimmingCharacters(in: .whitespaces), []))
            }
        }

        sections = mergeAdjacentSections(sections)

        var out: [String] = []
        for section in sections where !section.verses.isEmpty {
            if !out.isEmpty { out.append("") }  // blank line between passages
            if !section.title.isEmpty {
                out.append(pretty ? Ansi.bold + section.title + Ansi.reset
                                  : section.title)
                if pretty { out.append("") }    // breathing room under heading
            }

            // Label "7:1" style only when the passage crosses chapters.
            let multiChapter = Set(section.verses.map { $0.chapter }).count > 1
            for v in section.verses {
                let label = multiChapter ? "\(v.chapter):\(v.verse)" : "\(v.verse)"
                if pretty {
                    out.append(Ansi.dim + label + Ansi.reset + " " + v.text)
                } else {
                    out.append("\(label) \(v.text)")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Rich-text clipboard rendering

    /// Builds styled HTML for the clipboard: serif font, bold small-caps
    /// title, superscript verse numbers, paragraphs at the site's pericope
    /// marks, indented poetry, true italics and small-caps. Pastes into
    /// Messages, Notes, and Mail looking like the website (minus nav and
    /// footer).
    static func buildClipboardHTML(from html: String) throws -> String {
        let doc = try SwiftSoup.parse(html)
        // Keep the site's exact spacing: pretty-printing can reflow
        // whitespace around inline tags.
        _ = doc.outputSettings().prettyPrint(pretty: false)

        struct VerseItem: VerseRef {
            let book: Int
            let chapter: Int
            let verse: Int
            let subhead: String?
            let newParagraph: Bool
            let body: String
        }
        var sections: [(title: String, verses: [VerseItem])] = []

        for el in try doc.select("[class*=StyledPassageTitle], span.verse").array() {
            if el.hasClass("verse") {
                let parts = try el.attr("data-key").split(separator: "-")
                let book    = parts.count == 3 ? Int(parts[0]) ?? 0 : 0
                let chapter = parts.count == 3 ? Int(parts[1]) ?? 0 : 0
                let verse   = parts.count == 3 ? Int(parts[2]) ?? 0 : 0

                let subheadEl = try el.select("h3").first()
                let subhead = subheadEl != nil ? try subheadEl!.text() : nil
                let newParagraph = try !el.select("span.start-pericope").isEmpty()

                try el.select("h2, h3, small, span.start-pericope").remove()

                var body = try el.html()
                body = body
                    .replacingOccurrences(of: "<i class=\"float\"></i>", with: "")
                    .replacingOccurrences(of: "<div></div>", with: "")
                    .replacingOccurrences(of: " class=\"prose\"", with: "")
                    .replacingOccurrences(of: " class=\"padding-right\"", with: "")
                    .replacingOccurrences(of: "class=\"poetry double-quote\"",
                                          with: "style=\"margin-left:2em\"")
                    .replacingOccurrences(of: "class=\"poetry\"",
                                          with: "style=\"margin-left:2em\"")
                    .replacingOccurrences(of: "class=\"small-caps\"",
                                          with: "style=\"font-variant:small-caps\"")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }

                if sections.isEmpty { sections.append(("", [])) }
                sections[sections.count - 1].verses.append(VerseItem(
                    book: book, chapter: chapter, verse: verse,
                    subhead: subhead, newParagraph: newParagraph, body: body))
            } else {
                sections.append((try el.text().trimmingCharacters(in: .whitespaces), []))
            }
        }

        sections = mergeAdjacentSections(sections)

        var out = "<div style=\"font-family: Georgia, 'Times New Roman', serif; font-size:16px; line-height:1.45;\">"
        var firstSection = true

        for section in sections where !section.verses.isEmpty {
            // Blank line between passages. Messages flattens CSS margins,
            // so the gap must be explicit content.
            if !firstSection { out += "<div><br></div>" }
            firstSection = false

            if !section.title.isEmpty {
                // <b> so the title still stands out in apps (Messages)
                // that strip font-size and font-variant styling.
                out += "<div style=\"font-size:1.35em; font-variant:small-caps; "
                    + "letter-spacing:0.02em; margin:0.6em 0 0.5em 0;\"><b>"
                    + section.title + "</b></div>"
            }

            let multiChapter = Set(section.verses.map { $0.chapter }).count > 1
            var paragraph: [String] = []

            func flushParagraph() {
                if !paragraph.isEmpty {
                    out += "<div style=\"margin:0 0 0.7em 0;\">"
                        + paragraph.joined(separator: " ") + "</div>"
                    paragraph = []
                }
            }

            var lastChapter: Int? = nil
            for v in section.verses {
                // Blank line before a chapter change mid-passage, for the
                // same margin-stripping reason as above.
                if let lc = lastChapter, v.chapter != lc {
                    flushParagraph()
                    out += "<div><br></div>"
                }
                lastChapter = v.chapter

                if v.newParagraph || v.subhead != nil { flushParagraph() }
                if let subhead = v.subhead {
                    // <b><i> so section headings still stand out in apps
                    // (Messages) that strip font-variant styling — and
                    // stay distinguishable from the bold passage titles.
                    out += "<div style=\"font-variant:small-caps; "
                        + "margin:0.9em 0 0.3em 0;\"><b><i>"
                        + subhead + "</i></b></div>"
                }
                let label = multiChapter ? "\(v.chapter):\(v.verse)" : "\(v.verse)"
                paragraph.append("<sup><b>\(label)</b></sup> " + v.body)
            }
            flushParagraph()
        }

        out += "</div>"
        // Encode all non-ASCII characters (curly quotes, em dashes) as
        // numeric HTML entities so receiving apps can't misread the
        // encoding — the cause of the "â€œ" artifacts in Messages.
        return out.unicodeScalars
            .map { $0.isASCII ? String($0) : "&#\($0.value);" }
            .joined()
    }

    static func err(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }
}
