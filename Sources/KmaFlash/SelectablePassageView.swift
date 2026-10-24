import AppKit
import SwiftUI

enum ReadingSpanRole: String {
    case title, subtitle, hint, caption, heading, body, quote
}

struct ReadingSpan: Identifiable {
    let id: String
    let text: String
    let role: ReadingSpanRole
    var block: ContentBlock?
}

enum ReadingTextCommand {
    case note(String)
    case copy(String)
    case explain(String, ContentBlock?)
    case discuss(String, ContentBlock?)
    case bookmark(ContentBlock)
}

/// 整章放在同一个可选文字视图里。选区交给 SwiftUI 工具条，右键走系统菜单，避免弹出层被同一次点击关掉。
struct FlowReadingCanvas: NSViewRepresentable {
    var spans: [ReadingSpan]
    var textColor: Color
    var secondaryColor: Color
    var accentColor: Color
    var backgroundColor: Color
    var highlightColor: Color
    var lineSpacing: CGFloat
    var bodySize: CGFloat = 17
    var bookLayout: Bool = false
    var highlightSpanId: String
    var citationSpanId: String
    var scrollToSpanId: String
    var onSelection: (String, ContentBlock?) -> Void
    var onCommand: (ReadingTextCommand) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ReadingHostScrollView {
        let host = ReadingHostScrollView()
        host.textView.delegate = context.coordinator
        return host
    }

    func updateNSView(_ host: ReadingHostScrollView, context: Context) {
        context.coordinator.onCommand = onCommand
        context.coordinator.onSelection = onSelection
        host.bookLayout = bookLayout
        host.textView.onCommand = onCommand
        host.textView.onSelection = onSelection
        host.textView.delegate = context.coordinator
        let signature = Self.signature(
            spans: spans,
            text: textColor,
            secondary: secondaryColor,
            background: backgroundColor,
            highlight: highlightColor,
            spacing: lineSpacing,
            bodySize: bodySize,
            bookLayout: bookLayout,
            highlightSpanId: highlightSpanId,
            citationSpanId: citationSpanId
        )
        host.drawsBackground = true
        host.backgroundColor = NSColor(backgroundColor)
        if host.signature != signature {
            let built = Self.build(
                spans: spans,
                text: NSColor(textColor),
                secondary: NSColor(secondaryColor),
                highlight: NSColor(highlightColor),
                lineSpacing: lineSpacing,
                bodySize: bodySize,
                bookLayout: bookLayout,
                highlightSpanId: highlightSpanId,
                citationSpanId: citationSpanId
            )
            let origin = host.contentView.documentVisibleRect.origin
            let savedSelection = host.textView.selectedRange()
            host.signature = signature
            host.ranges = built.ranges
            host.blocks = built.blocks
            host.textView.textStorage?.setAttributedString(built.string)
            host.textView.textContainer?.containerSize.width = 0 // Recompute height after chapter or streamed guide changes.
            if savedSelection.length > 0, NSMaxRange(savedSelection) <= built.string.length {
                host.textView.setSelectedRange(savedSelection)
            }
            host.relayoutText()
            if scrollToSpanId.isEmpty {
                host.contentView.scroll(to: origin)
            }
        }
        if host.scrollTarget != scrollToSpanId {
            host.scrollTarget = scrollToSpanId
            let target = scrollToSpanId
            DispatchQueue.main.async {
                host.scrollToSpan(target)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReadingHostScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 720, height: proposal.height ?? 640)
    }

    private static func signature(
        spans: [ReadingSpan],
        text: Color,
        secondary: Color,
        background: Color,
        highlight: Color,
        spacing: CGFloat,
        bodySize: CGFloat,
        bookLayout: Bool,
        highlightSpanId: String,
        citationSpanId: String
    ) -> String {
        let body = spans.map { "\($0.id)|\($0.role.rawValue)|\($0.text.hashValue)" }.joined(separator: "§")
        return "\(body)|\(colorKey(text))|\(colorKey(secondary))|\(colorKey(background))|\(colorKey(highlight))|\(spacing)|\(bodySize)|\(bookLayout)|\(highlightSpanId)|\(citationSpanId)"
    }

    private static func colorKey(_ color: Color) -> String {
        let rgb = NSColor(color).usingColorSpace(.sRGB)
        guard let rgb else { return "" }
        return String(format: "%.3f-%.3f-%.3f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }

    private static func build(
        spans: [ReadingSpan],
        text: NSColor,
        secondary: NSColor,
        highlight: NSColor,
        lineSpacing: CGFloat,
        bodySize: CGFloat,
        bookLayout: Bool,
        highlightSpanId: String,
        citationSpanId: String
    ) -> (string: NSAttributedString, ranges: [String: NSRange], blocks: [(NSRange, ContentBlock)]) {
        let result = NSMutableAttributedString()
        var ranges: [String: NSRange] = [:]
        var blocks: [(NSRange, ContentBlock)] = []
        for (index, span) in spans.enumerated() {
            let start = result.length
            let chunk = displayText(span.text, role: span.role, bookLayout: bookLayout)
            let attrs = attributes(
                for: span,
                text: text,
                secondary: secondary,
                highlight: highlight,
                lineSpacing: lineSpacing,
                bodySize: bodySize,
                bookLayout: bookLayout,
                marked: span.id == highlightSpanId || span.id == citationSpanId
            )
            result.append(NSAttributedString(string: chunk, attributes: attrs))
            let range = NSRange(location: start, length: result.length - start)
            ranges[span.id] = range
            if let block = span.block, span.role == .body || span.role == .quote {
                blocks.append((range, block))
            }
            if index < spans.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
        if result.length == 0 {
            result.append(NSAttributedString(string: " ", attributes: bodyAttributes(text: text, secondary: secondary, spacing: lineSpacing, bodySize: bodySize)))
        }
        return (result, ranges, blocks)
    }

    private static func attributes(
        for span: ReadingSpan,
        text: NSColor,
        secondary: NSColor,
        highlight: NSColor,
        lineSpacing: CGFloat,
        bodySize: CGFloat,
        bookLayout: Bool,
        marked: Bool
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = bookLayout ? 2 : min(lineSpacing, 4)
        paragraph.paragraphSpacing = bookLayout ? 8 : 10
        let delta = bodySize - 17
        var font = serif(bodySize)
        var color = text
        switch span.role {
        case .title:
            font = serif(26 + delta, weight: .bold)
            paragraph.paragraphSpacing = 4
            paragraph.paragraphSpacingBefore = bookLayout ? 2 : 0
            paragraph.lineSpacing = 1
        case .subtitle:
            font = serif(max(13, 15 + delta), weight: .semibold)
            color = secondary
            paragraph.paragraphSpacing = 6
            paragraph.lineSpacing = 1
        case .hint, .caption:
            font = NSFont.systemFont(ofSize: 12)
            color = secondary
            paragraph.lineSpacing = 1
            paragraph.paragraphSpacing = bookLayout ? 8 : 6
        case .heading:
            font = serif(18 + delta, weight: .semibold)
            paragraph.paragraphSpacingBefore = bookLayout ? 14 : 12
            paragraph.paragraphSpacing = 4
            paragraph.lineSpacing = 1
        case .quote:
            font = serif(max(14, 16 + delta))
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            font = italic
            color = secondary
            paragraph.headIndent = 16
            paragraph.firstLineHeadIndent = 16
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = 8
        case .body:
            font = serif(bodySize)
            paragraph.lineSpacing = bookLayout ? 2 : 3
            paragraph.paragraphSpacing = bookLayout ? 8 : 10
            if bookLayout {
                paragraph.firstLineHeadIndent = 34
            }
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        if marked {
            attrs[.backgroundColor] = highlight.withAlphaComponent(0.95)
        }
        return attrs
    }

    private static func displayText(_ raw: String, role: ReadingSpanRole, bookLayout: Bool) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bookLayout, role == .body || role == .quote else { return trimmed }
        let paragraphs = trimmed.components(separatedBy: "\n\n").map { part in
            part.replacingOccurrences(of: "\n", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return paragraphs.joined(separator: "\n")
    }

    private static func bodyAttributes(text: NSColor, secondary: NSColor, spacing: CGFloat, bodySize: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = spacing
        return [.font: serif(bodySize), .foregroundColor: text, .paragraphStyle: paragraph]
    }

    private static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onCommand: ((ReadingTextCommand) -> Void)?
        var onSelection: ((String, ContentBlock?) -> Void)?

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? ReadingTextView)?.publishSelection()
        }
    }
}

final class ReadingHostScrollView: NSScrollView {
    let textView = ReadingTextView()
    var signature = ""
    var bookLayout = false
    var scrollTarget = ""
    var ranges: [String: NSRange] = [:]
    var blocks: [(NSRange, ContentBlock)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = true
        documentView = textView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 40, height: 20)
        textView.textContainer?.lineFragmentPadding = 2
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.host = self
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private var rightClickMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let rightClickMonitor {
            NSEvent.removeMonitor(rightClickMonitor)
            self.rightClickMonitor = nil
        }
        guard window != nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, let hostWindow = self.window, event.window === hostWindow else { return event }
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(local) else { return event }
            self.textView.rightMouseDown(with: event)
            return nil
        }
    }

    deinit {
        if let rightClickMonitor {
            NSEvent.removeMonitor(rightClickMonitor)
        }
    }

    private var layingOut = false

    override func layout() {
        super.layout()
        guard !layingOut else { return }
        layingOut = true
        relayoutText()
        layingOut = false
    }

    func relayoutText() {
        let width = max(contentSize.width, 240)
        let column: CGFloat = bookLayout ? 680 : 760
        let side = max(36, floor((width - column) / 2))
        let inset = NSSize(width: side, height: 18)
        if textView.textContainerInset.width != inset.width || textView.textContainerInset.height != inset.height {
            textView.textContainerInset = inset
        }
        let containerWidth = max(width - textView.textContainerInset.width * 2, 280)
        let currentWidth = textView.textContainer?.containerSize.width ?? 0
        guard abs(currentWidth - containerWidth) > 1 || textView.frame.width < 10 else { return }
        let saved = textView.selectedRange()
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(textView.frame.height, contentSize.height))
        textView.textContainer?.containerSize = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let height = max(ceil(used.height) + textView.textContainerInset.height * 2 + 8, contentSize.height)
        textView.frame.size = NSSize(width: width, height: height)
        if saved.location != NSNotFound, NSMaxRange(saved) <= (textView.string as NSString).length {
            textView.setSelectedRange(saved)
        }
    }

    func block(at location: Int) -> ContentBlock? {
        blocks.first { NSLocationInRange(location, $0.0) }?.1
            ?? blocks.min { abs($0.0.location - location) < abs($1.0.location - location) }?.1
    }

    func scrollToSpan(_ id: String) {
        guard !id.isEmpty, let range = ranges[id] else { return }
        relayoutText()
        textView.scrollRangeToVisible(range)
    }
}

final class ReadingTextView: NSTextView {
    weak var host: ReadingHostScrollView?
    var onCommand: ((ReadingTextCommand) -> Void)?
    var onSelection: ((String, ContentBlock?) -> Void)?
    private var lastPublished = " "
    private var selectionPopover: NSView?
    private var toolbarClickMonitor: Any?

    private var selectionWork: DispatchWorkItem?
    private var selectionObservers: [NSObjectProtocol] = []
    private var observedScrollOrigin: NSPoint?
    private var lastPublishedRange = NSRange(location: NSNotFound, length: 0)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        selectionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        selectionObservers.removeAll()
        dismissSelectionActions()
        guard window != nil else { return }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observedScrollOrigin = clip.bounds.origin
            selectionObservers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak clip] _ in
                guard let self, let clip else { return }
                let origin = clip.bounds.origin
                guard self.observedScrollOrigin != origin else { return }
                self.observedScrollOrigin = origin
                self.dismissSelectionActions()
            })
        }
        selectionObservers.append(NotificationCenter.default.addObserver(forName: Notification.Name("TongyeReadingSelectionWillPresent"), object: nil, queue: .main) { [weak self] note in
            guard let self, let sender = note.object as? ReadingTextView, sender !== self else { return }
            self.dismissSelectionActions()
        })
    }

    private func dismissSelectionActions() {
        selectionWork?.cancel(); selectionWork = nil
        if let monitor = toolbarClickMonitor { NSEvent.removeMonitor(monitor) }
        toolbarClickMonitor = nil
        selectionPopover?.removeFromSuperview(); selectionPopover = nil
        window?.invalidateCursorRects(for: self)
    }

    private func scheduleSelectionActions() {
        selectionWork?.cancel()
        guard !currentSelection().isEmpty else { dismissSelectionActions(); return }
        let work = DispatchWorkItem { [weak self] in self?.showSelectionActions() }
        selectionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func showSelectionActions() {
        guard NSEvent.pressedMouseButtons == 0, let window, window.isVisible else { return }
        let text = currentSelection(), range = selectedRange()
        guard !text.isEmpty, range.location != NSNotFound, range.length > 0 else { dismissSelectionActions(); return }
        // NSTextInputClient returns the first selected line in screen coordinates.
        // Anchor to the visible end when the beginning is outside the viewport.
        func localRect(_ selection: NSRange) -> NSRect {
            convert(window.convertFromScreen(firstRect(forCharacterRange: selection, actualRange: nil)), from: nil)
        }
        var anchor = localRect(range).intersection(visibleRect)
        if anchor.isNull || anchor.isEmpty { anchor = localRect(NSRange(location: NSMaxRange(range) - 1, length: 1)).intersection(visibleRect) }
        guard !anchor.isNull, !anchor.isEmpty else { dismissSelectionActions(); return }
        let block = host?.block(at: range.location)
        dismissSelectionActions()
        NotificationCenter.default.post(name: Notification.Name("TongyeReadingSelectionWillPresent"), object: self)
        guard let root = window.contentView else { return }
        let command = onCommand
        let popover = SelectionToolbarView(hasBookmark: block != nil) { [weak self] action in
            guard let self else { return }
            self.dismissSelectionActions()
            switch action {
            case 0: command?(.note(text))
            case 1: command?(.copy(text))
            case 2: command?(.explain(text, block))
            case 3: command?(.discuss(text, block))
            default: if let block { command?(.bookmark(block)) }
            }
        }
        let size = NSSize(width: block == nil ? 400 : 500, height: 52)
        let target = convert(anchor, to: root)
        let margin: CGFloat = 8
        let proposedY = root.isFlipped ? target.minY - size.height - margin : target.maxY + margin
        let oppositeY = root.isFlipped ? target.maxY + margin : target.minY - size.height - margin
        let fits = proposedY >= margin && proposedY + size.height <= root.bounds.height - margin
        let y = fits ? proposedY : oppositeY
        popover.frame = NSRect(x: min(max(margin, target.midX - size.width / 2), root.bounds.width - size.width - margin), y: min(max(margin, y), root.bounds.height - size.height - margin), width: size.width, height: size.height)
        popover.pointsDown = fits
        popover.pointerX = min(max(18, target.midX - popover.frame.minX), size.width - 18)
        popover.wantsLayer = true
        popover.layer?.shadowOpacity = 0.18
        popover.layer?.shadowRadius = 8
        popover.layer?.shadowOffset = CGSize(width: 0, height: -2)
        root.addSubview(popover, positioned: .above, relativeTo: nil)
        selectionPopover = popover
        // Route toolbar clicks before SwiftUI's root can send them to reader content.
        toolbarClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak popover, weak window] event in
            guard let popover, event.window === window,
                  let target = popover.hitTest(popover.superview?.convert(event.locationInWindow, from: nil) ?? .zero) else { return event }
            target.mouseDown(with: event)
            return nil
        }
        window.invalidateCursorRects(for: popover)
    }

    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        scheduleSelectionActions()
    }

    deinit {
        selectionWork?.cancel()
        if let monitor = toolbarClickMonitor { NSEvent.removeMonitor(monitor) }
        selectionPopover?.removeFromSuperview()
        selectionObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }


    func currentSelection() -> String {
        let range = selectedRange()
        guard range.length > 0, range.location != NSNotFound else { return "" }
        let source = string as NSString
        guard NSMaxRange(range) <= source.length else { return "" }
        return source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func publishSelection() {
        let selected = currentSelection()
        guard selected != lastPublished || selectedRange() != lastPublishedRange else { return }
        lastPublishedRange = selectedRange()
        lastPublished = selected
        let block = selected.isEmpty ? nil : host?.block(at: selectedRange().location)
        onSelection?(selected, block)
        scheduleSelectionActions()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dismissSelectionActions()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        scheduleSelectionActions()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        publishSelection()
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let current = selectedRange()
        if current.length == 0 || index >= (string as NSString).length || !NSLocationInRange(index, current) {
            selectParagraph(at: index)
        }
        publishSelection()
        dismissSelectionActions()
        guard !currentSelection().isEmpty else { return }
        NSMenu.popUpContextMenu(selectionMenu(), with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        selectionMenu()
    }

    private func selectParagraph(at index: Int) {
        let source = string as NSString
        guard source.length > 0 else { return }
        let safe = min(max(index, 0), source.length - 1)
        var range = source.paragraphRange(for: NSRange(location: safe, length: 0))
        let chunk = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        if chunk.isEmpty { return }
        let leading = (source.substring(with: range) as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted).location
        if leading != NSNotFound {
            let start = range.location + leading
            let end = range.location + range.length
            range = NSRange(location: start, length: max(end - start, 0))
        }
        setSelectedRange(range)
    }

    private func selectionMenu() -> NSMenu {
        let menu = NSMenu(title: "选区")
        let titles = ["记笔记", "复制", "解释这句", "一起讨论", "标为读到这里"]
        for (offset, title) in titles.enumerated() {
            if offset == 4, host?.block(at: selectedRange().location) == nil { continue }
            let item = NSMenuItem(title: title, action: #selector(runSelectionCommand(_:)), keyEquivalent: "")
            item.tag = offset + 1
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func runSelectionCommand(_ sender: NSMenuItem) {
        let text = currentSelection()
        guard !text.isEmpty else { return }
        let block = host?.block(at: selectedRange().location)
        switch sender.tag {
        case 1: onCommand?(.note(text))
        case 2: onCommand?(.copy(text))
        case 3: onCommand?(.explain(text, block))
        case 4: onCommand?(.discuss(text, block))
        case 5: if let block { onCommand?(.bookmark(block)) }
        default: break
        }
    }
}

struct ContentBlock { let id: String; let text: String }

final class SelectionToolbarView: NSView {
    private(set) var buttons: [NSButton] = []
    var pointsDown = true { didSet { needsDisplay = true; needsLayout = true } }
    var pointerX: CGFloat = 190 { didSet { needsDisplay = true } }
    private let run: (Int) -> Void
    override var isFlipped: Bool { true }
    init(hasBookmark: Bool, run: @escaping (Int) -> Void) {
        self.run = run
        super.init(frame: .zero)
        var actions = [("记笔记", "square.and.pencil"), ("复制", "doc.on.doc"), ("解释这句", "text.bubble"), ("一起讨论", "bubble.left.and.bubble.right")]
        if hasBookmark { actions.append(("读到这里", "bookmark")) }
        for (index, action) in actions.enumerated() {
            let button = SelectionToolbarButton(title: action.0, target: self, action: #selector(activate(_:)))
            button.tag = index
            button.image = NSImage(systemSymbolName: action.1, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.isBordered = false
            button.focusRingType = .none
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.setAccessibilityLabel(action.0)
            buttons.append(button); addSubview(button)
        }
    }
    required init?(coder: NSCoder) { nil }
    @objc private func activate(_ sender: NSButton) {
        // Retain the command while it dismisses this view and changes the reader.
        let command = run
        command(sender.tag)
    }
    override func layout() {
        super.layout()
        let width = (bounds.width - 12) / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 6 + CGFloat(index) * width, y: pointsDown ? 6 : 14, width: width - 2, height: 32)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 0, y: pointsDown ? 0 : 8, width: bounds.width, height: bounds.height - 8)
        let path = NSBezierPath(roundedRect: body, xRadius: 10, yRadius: 10)
        let edge = pointsDown ? body.maxY : body.minY
        path.move(to: NSPoint(x: pointerX - 8, y: edge))
        path.line(to: NSPoint(x: pointerX, y: pointsDown ? bounds.maxY : bounds.minY))
        path.line(to: NSPoint(x: pointerX + 8, y: edge)); path.close()
        NSColor.windowBackgroundColor.setFill(); path.fill()
        NSColor.separatorColor.setStroke(); path.lineWidth = 0.5; path.stroke()
    }
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class SelectionToolbarButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovered = false { didSet { updateAppearance() } }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; NSCursor.arrow.set() }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func draw(_ dirtyRect: NSRect) {
        let active = hovered || isHighlighted
        if active { NSColor.controlAccentColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        super.draw(dirtyRect)
    }
    override func highlight(_ flag: Bool) { super.highlight(flag); updateAppearance() }
    private func updateAppearance() {
        let active = hovered || isHighlighted
        contentTintColor = active ? .white : .labelColor
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: active ? NSColor.white : .labelColor])
        needsDisplay = true
    }
}
