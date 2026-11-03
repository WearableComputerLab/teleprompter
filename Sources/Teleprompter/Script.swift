import AppKit
import NaturalLanguage
import PDFKit

/// How the script's paragraphs are turned into spoken text.
enum ParseMode: String, CaseIterable, Identifiable {
    case auto, screenplay, allText
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .screenplay: return "Screenplay (dialogue only)"
        case .allText: return "All text"
        }
    }
}

/// One spoken sentence of the script.
struct Sentence: Identifiable {
    let id: Int
    let text: String
    /// Indices into `Script.words` for this sentence.
    let wordRange: Range<Int>
    /// Stage directions that appear between the previous sentence and this one.
    let directionsBefore: [String]
}

/// A word of spoken text, normalised for matching against speech recognition.
struct ScriptWord {
    let norm: String
    let sentence: Int
    /// Character range of the word inside its sentence's text.
    let range: Range<String.Index>
}

/// A row shown in the full-script list of the control window.
enum ScriptRow: Identifiable {
    case heading(Int, String)
    case direction(Int, String)
    case cue(Int, String)
    case sentence(Int, Sentence)

    var id: Int {
        switch self {
        case .heading(let i, _), .direction(let i, _), .cue(let i, _), .sentence(let i, _): return i
        }
    }
}

struct Script {
    var title: String
    var sentences: [Sentence] = []
    var words: [ScriptWord] = []
    var rows: [ScriptRow] = []
    var detectedScreenplay = false

    static let empty = Script(title: "No script loaded")

    /// Words worth giving the recogniser as hints (names, jargon, long words).
    var vocabularyHints: [String] {
        var seen = Set<String>()
        var hints: [String] = []
        for s in sentences {
            for w in words[s.wordRange] {
                let original = String(s.text[w.range])
                let isAcronym = original.count >= 2 && !original.contains(where: { $0.isLowercase })
                let isName = original.count >= 4 && original.first?.isUppercase == true && w.range.lowerBound != s.text.startIndex
                let isUnusual = original.count >= 9 || isAcronym || isName
                if isUnusual, !original.contains("'"), !original.contains("’"), seen.insert(w.norm).inserted {
                    hints.append(original)
                }
            }
        }
        return Array(hints.prefix(100))
    }
}

// MARK: - Loading

struct Paragraph {
    var text: String
    var indent: CGFloat
    var bold: Bool
    var centered: Bool
}

enum ScriptLoader {
    static func load(url: URL, mode: ParseMode) throws -> Script {
        let paragraphs = try readParagraphs(url: url)
        return build(paragraphs: paragraphs, mode: mode, title: url.deletingPathExtension().lastPathComponent)
    }

    static func readParagraphs(url: URL) throws -> [Paragraph] {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url), let text = doc.string else {
                throw NSError(domain: "Teleprompter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read PDF text."])
            }
            return plainParagraphs(text)
        }
        if ["txt", "md", "markdown", "fountain", "text", ""].contains(ext) {
            return plainParagraphs(try String(contentsOf: url, encoding: .utf8))
        }
        // docx, doc, rtf, rtfd, odt, html, webarchive...
        let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        let string = attributed.string as NSString
        var result: [Paragraph] = []
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            let text = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let bold = font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
            result.append(Paragraph(text: text,
                                    indent: style?.headIndent ?? 0,
                                    bold: bold,
                                    centered: style?.alignment == .center))
            location = NSMaxRange(range)
        }
        return result
    }

    private static func plainParagraphs(_ text: String) -> [Paragraph] {
        text.components(separatedBy: .newlines).map { line in
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 36 : 6) }
            return Paragraph(text: line.trimmingCharacters(in: .whitespaces), indent: CGFloat(indent), bold: false, centered: false)
        }
    }

    // MARK: Classification

    private static let transitionPrefixes = ["INT.", "EXT.", "INT/", "EXT/", "I/E", "FADE", "CUT TO", "DISSOLVE", "SMASH CUT",
                                             "MATCH CUT", "PART ", "SCENE ", "ACT ", "THE END", "TITLE", "SUPER:", "BACK TO", "END OF"]

    private static func isTransitionOrHeading(_ p: Paragraph) -> Bool {
        let upper = p.text.uppercased()
        return transitionPrefixes.contains { upper.hasPrefix($0) }
    }

    static func isCue(_ text: String) -> Bool {
        guard (2...60).contains(text.count),
              text.contains(where: { $0.isLetter }),
              !text.contains(where: { $0.isLowercase }),
              !text.hasSuffix(":") else { return false }
        let upper = text.uppercased()
        if transitionPrefixes.contains(where: { upper.hasPrefix($0) }) { return false }
        // Strip parenthetical extensions like (V.O.) (CONT'D); the name itself shouldn't end a sentence.
        let name = text.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        return !name.isEmpty && !name.hasSuffix(".") && !name.hasSuffix("!") && !name.hasSuffix("?")
    }

    private static func isParenthetical(_ text: String) -> Bool {
        text.hasPrefix("(") && text.hasSuffix(")")
    }

    private static func isTimestamp(_ text: String) -> Bool {
        text.range(of: #"^\(\s*\d{1,2}(:\d{2}){1,2}\s*\)$"#, options: .regularExpression) != nil
    }

    static func build(paragraphs: [Paragraph], mode: ParseMode, title: String) -> Script {
        let hasIndents = paragraphs.contains { $0.indent > 1 }
        // Count cues directly followed (ignoring parentheticals) by text.
        var cueCount = 0
        for (i, p) in paragraphs.enumerated() where isCue(p.text) {
            if let next = paragraphs[(i + 1)...].first(where: { !$0.text.isEmpty && !isParenthetical($0.text) }),
               !isCue(next.text) {
                cueCount += 1
            }
        }
        let screenplay: Bool
        switch mode {
        case .auto: screenplay = cueCount >= 2
        case .screenplay: screenplay = true
        case .allText: screenplay = false
        }

        var script = Script(title: title)
        script.detectedScreenplay = cueCount >= 2
        var rowID = 0
        var pendingDirections: [String] = []
        var inDialogue = false
        var dialogueIndent: CGFloat?

        func addSpoken(_ text: String) {
            for sentenceText in splitSentences(text) {
                let id = script.sentences.count
                let start = script.words.count
                for (norm, range) in tokenize(sentenceText) {
                    script.words.append(ScriptWord(norm: norm, sentence: id, range: range))
                }
                let sentence = Sentence(id: id, text: sentenceText, wordRange: start..<script.words.count,
                                        directionsBefore: pendingDirections)
                pendingDirections = []
                script.sentences.append(sentence)
                script.rows.append(.sentence(rowID, sentence)); rowID += 1
            }
        }

        for p in paragraphs {
            let text = p.text
            if !screenplay {
                if text.isEmpty { continue }
                if p.bold && p.centered || isTransitionOrHeading(p) && text.count < 80 && !text.contains(where: { $0.isLowercase }) {
                    script.rows.append(.heading(rowID, text)); rowID += 1
                } else {
                    addSpoken(text)
                }
                continue
            }

            if text.isEmpty {
                // In plain text a blank line ends a dialogue block; in Word documents indentation does.
                if !hasIndents { inDialogue = false }
                continue
            }
            if isCue(text) {
                inDialogue = true
                dialogueIndent = nil
                script.rows.append(.cue(rowID, text)); rowID += 1
                continue
            }
            if inDialogue && isParenthetical(text) {
                if !isTimestamp(text) {
                    script.rows.append(.direction(rowID, text)); rowID += 1
                    pendingDirections.append(text)
                }
                continue
            }
            if inDialogue {
                if hasIndents {
                    if let d = dialogueIndent {
                        if p.indent < d - 12 { inDialogue = false }
                    } else if p.indent > 1 {
                        dialogueIndent = p.indent
                    } else {
                        inDialogue = false
                    }
                }
                if inDialogue {
                    addSpoken(text)
                    continue
                }
            }
            // Action / heading / transition.
            if p.bold || p.centered || isTransitionOrHeading(p) {
                script.rows.append(.heading(rowID, text)); rowID += 1
            } else {
                script.rows.append(.direction(rowID, text)); rowID += 1
                pendingDirections.append(text)
            }
        }
        return script
    }

    static func splitSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out
    }

    static func tokenize(_ text: String) -> [(String, Range<String.Index>)] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var out: [(String, Range<String.Index>)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let n = normalize(String(text[range]))
            if !n.isEmpty { out.append((n, range)) }
            return true
        }
        return out
    }

    static func normalize(_ word: String) -> String {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Normalised words of a recogniser transcript.
    static func transcriptWords(_ text: String) -> [String] {
        tokenize(text).map { $0.0 }
    }
}
