import SwiftUI
import AppKit

/// A Python code editor: monospaced, syntax colours, 4-space tabs, auto-indent, and a highlighted error line.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var errorLine: Int?
    /// Set to a line number to scroll there and select it.
    var jumpTo: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.font = Coordinator.font
        tv.textColor = Coordinator.plain
        tv.backgroundColor = NSColor(srgbRed: 0.043, green: 0.071, blue: 0.098, alpha: 1)
        tv.insertionPointColor = NSColor(srgbRed: 0, green: 0.84, blue: 0.77, alpha: 1)
        tv.selectedTextAttributes = [.backgroundColor: NSColor(srgbRed: 0.07, green: 0.25, blue: 0.27, alpha: 1)]
        tv.textContainerInset = NSSize(width: 8, height: 10)
        tv.string = text
        scroll.drawsBackground = true
        scroll.backgroundColor = tv.backgroundColor
        context.coordinator.textView = tv
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        if tv.string != text {
            tv.string = text
            c.highlight()
        } else if c.lastError != errorLine {
            c.highlight()
        }
        if let line = jumpTo, line != c.lastJump {
            c.lastJump = line
            c.select(line: line)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        var lastError: Int?
        var lastJump: Int?

        static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        static let plain = NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1)
        static let keyword = NSColor(srgbRed: 0.98, green: 0.47, blue: 0.62, alpha: 1)
        static let string = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.45, alpha: 1)
        static let number = NSColor(srgbRed: 0.70, green: 0.62, blue: 1.0, alpha: 1)
        static let comment = NSColor(srgbRed: 0.45, green: 0.55, blue: 0.62, alpha: 1)
        static let apiColor = NSColor(srgbRed: 0.10, green: 0.90, blue: 0.88, alpha: 1)
        static let errorBack = NSColor(srgbRed: 0.45, green: 0.08, blue: 0.12, alpha: 0.55)

        static let rules: [(NSRegularExpression, NSColor)] = {
            func r(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) }
            let kw = ["def", "return", "for", "in", "if", "elif", "else", "while", "import", "from", "as", "and", "or", "not",
                      "True", "False", "None", "lambda", "with", "try", "except", "pass", "break", "continue", "class"]
            let api = ["canvas", "brush", "layer", "stroke", "strokes", "line", "circle", "ellipse", "rect", "arc", "polygon",
                       "color", "mix", "lighten", "darken", "hsv", "gradient", "palette_from", "picture_palette", "load_picture",
                       "paint", "ink", "draw_on", "boil", "glow", "shadow", "effect", "modifier", "smooth_path", "plan_paint",
                       "plan_ink", "IMAGE"]
            return [
                (r("\\b(" + api.joined(separator: "|") + ")\\b"), Coordinator.apiColor),
                (r("\\b(" + kw.joined(separator: "|") + ")\\b"), Coordinator.keyword),
                (r("\\b\\d+(\\.\\d+)?\\b"), Coordinator.number),
                (r("#[0-9a-fA-F]{3,8}\\b"), Coordinator.number),
                (r("(\"\"\"[\\s\\S]*?\"\"\"|'[^'\\n]*'|\"[^\"\\n]*\")"), Coordinator.string),
                (r("(?<![\"'])#(?![0-9a-fA-F]{3,8}\\b).*$"), Coordinator.comment),
            ]
        }()

        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            highlight()
        }

        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            storage.beginEditing()
            storage.setAttributes([.font: Self.font, .foregroundColor: Self.plain], range: full)
            for (re, color) in Self.rules {
                re.enumerateMatches(in: tv.string, range: full) { m, _, _ in
                    if let m { storage.addAttribute(.foregroundColor, value: color, range: m.range) }
                }
            }
            lastError = parent.errorLine
            if let line = parent.errorLine, let range = lineRange(line) {
                storage.addAttribute(.backgroundColor, value: Self.errorBack, range: range)
            }
            storage.endEditing()
        }

        func lineRange(_ line: Int) -> NSRange? {
            guard let tv = textView, line >= 1 else { return nil }
            let ns = tv.string as NSString
            var start = 0, current = 1
            while current < line {
                let r = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
                if r.location == NSNotFound { return nil }
                start = r.location + 1
                current += 1
            }
            return ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0))
        }

        func select(line: Int) {
            guard let tv = textView, let r = lineRange(line) else { return }
            tv.setSelectedRange(r)
            tv.scrollRangeToVisible(r)
            tv.window?.makeFirstResponder(tv)
        }

        /// Tab inserts four spaces; Return keeps the indent (and adds four after a colon).
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) {
                textView.insertText("    ", replacementRange: textView.selectedRange())
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let ns = textView.string as NSString
                let sel = textView.selectedRange()
                let lr = ns.lineRange(for: NSRange(location: sel.location, length: 0))
                let line = ns.substring(with: NSRange(location: lr.location, length: sel.location - lr.location))
                var indent = String(line.prefix { $0 == " " })
                if line.trimmingCharacters(in: .whitespaces).hasSuffix(":") { indent += "    " }
                textView.insertText("\n" + indent, replacementRange: sel)
                return true
            }
            return false
        }
    }
}
