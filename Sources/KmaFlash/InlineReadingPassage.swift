import AppKit
import SwiftUI

/// A self-sizing native text view inside the digest's existing SwiftUI ScrollView.
/// Shares selection and menu dispatch with original reading, without adding a nested scroller.
struct InlineReadingPassage: NSViewRepresentable {
    let text: String
    let size: CGFloat
    let color: Color
    var italic = false
    var markdown = false
    let onSelection: (String) -> Void
    let onCommand: (ReadingTextCommand) -> Void

    func makeCoordinator() -> FlowReadingCanvas.Coordinator { FlowReadingCanvas.Coordinator() }

    func makeNSView(context: Context) -> ReadingTextView {
        let view = ReadingTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: ReadingTextView, context: Context) {
        view.onCommand = onCommand
        view.onSelection = { selected, _ in
            // Selection changes caused by layout must not mutate SwiftUI during its update.
            DispatchQueue.main.async { onSelection(selected) }
        }
        let value = Self.formatted(text: text, size: size, color: NSColor(color), italic: italic, markdown: markdown)
        if !view.attributedString().isEqual(to: value) {
            let selected = view.selectedRange()
            view.textStorage?.setAttributedString(value)
            view.invalidateIntrinsicContentSize()
            if selected.location != NSNotFound, NSMaxRange(selected) <= value.length {
                view.setSelectedRange(selected)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReadingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: Self.fittingHeight(nsView.attributedString(), width: width))
    }

    static func fittingHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        // SwiftUI probes several widths; measuring must never resize the live text container.
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height) + 2
    }

    static func formatted(text: String, size: CGFloat, color: NSColor, italic: Bool, markdown: Bool) -> NSAttributedString {
        let parsed = markdown
            ? ((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            : AttributedString(text)
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = NSFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .bold : .regular)
            if italic || intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            result.append(NSAttributedString(string: String(parsed.characters[run.range]), attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph
            ]))
        }
        return result
    }
}
