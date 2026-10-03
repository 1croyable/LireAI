import SwiftUI
import UIKit

private struct AnswerCalligraphyKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var answerCalligraphy: Bool {
        get { self[AnswerCalligraphyKey.self] }
        set { self[AnswerCalligraphyKey.self] = newValue }
    }
}

struct SelectableAnswerText: UIViewRepresentable {
    @Environment(\.answerCalligraphy) private var calligraphy
    let text: String
    var size: CGFloat = 17
    var bold = false
    var secondary = false

    init(_ text: String, size: CGFloat = 17, bold: Bool = false, secondary: Bool = false) {
        self.text = text; self.size = size; self.bold = bold; self.secondary = secondary
    }
    func makeUIView(context: Context) -> UITextView {
        Self.makeTextView()
    }
    static func makeTextView() -> UITextView {
        let storage = NSTextStorage()
        let layout = ObliqueTextLayoutManager()
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = UITextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.clipsToBounds = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let rendered = Self.render(text, size: size, bold: bold, secondary: secondary, calligraphy: calligraphy)
        if view.attributedText != rendered { view.attributedText = rendered }
        view.accessibilityLabel = rendered.string
    }
    static func render(_ text: String, size: CGFloat, bold: Bool = false, secondary: Bool = false, calligraphy: Bool = true) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let rendered = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        var offset = 0
        for run in parsed.runs {
            let length = String(parsed[run.range].characters).utf16.count
            let range = NSRange(location: offset, length: length)
            let intent = run.inlinePresentationIntent ?? []
            let isBold = bold || intent.contains(.stronglyEmphasized)
            let font = ReadingTypography.appleFont(size: size, bold: isBold)
            rendered.addAttributes([.font: font, .foregroundColor: secondary ? UIColor.secondaryLabel : UIColor.label,
                                    .lireOblique: intent.contains(.emphasized)], range: range)
            var characterOffset = offset
            for character in parsed[run.range].characters {
                let count = String(character).utf16.count
                if ReadingTypography.isChinese(character) {
                    let chineseRange = NSRange(location: characterOffset, length: count)
                    rendered.addAttribute(.font, value: calligraphy ? ReadingTypography.font(size: size) : UIFont.systemFont(ofSize: size, weight: isBold ? .bold : .regular), range: chineseRange)
                    if isBold && calligraphy { rendered.addAttribute(.strokeWidth, value: -2.0, range: chineseRange) }
                }
                characterOffset += count
            }
            offset += length
        }
        return rendered
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }
}

extension NSAttributedString.Key {
    static let lireOblique = NSAttributedString.Key("LireAI.Oblique")
}

final class ObliqueTextLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange range: NSRange, at origin: CGPoint) {
        guard let storage = textStorage, let context = UIGraphicsGetCurrentContext() else {
            super.drawGlyphs(forGlyphRange: range, at: origin)
            return
        }
        enumerateLineFragments(forGlyphRange: range) { _, _, _, lineRange, _ in
            let visible = NSIntersectionRange(range, lineRange)
            let characters = self.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
            storage.enumerateAttribute(.lireOblique, in: characters) { value, characterRange, _ in
                let glyphs = NSIntersectionRange(visible, self.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil))
                guard glyphs.length > 0 else { return }
                context.saveGState()
                if value as? Bool == true {
                    let line = self.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                    let baseline = origin.y + line.minY + self.location(forGlyphAt: glyphs.location).y
                    context.translateBy(x: 0, y: baseline)
                    context.concatenate(CGAffineTransform(a: 1, b: 0, c: -0.24, d: 1, tx: 0, ty: 0))
                    context.translateBy(x: 0, y: -baseline)
                }
                self.drawRun(glyphs, at: origin)
                context.restoreGState()
            }
        }
    }
    private func drawRun(_ range: NSRange, at origin: CGPoint) {
        super.drawGlyphs(forGlyphRange: range, at: origin)
    }
}
