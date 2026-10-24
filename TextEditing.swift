import AppKit

struct EditorState: Equatable {
    var marks: [Mark]
    var selection: NSRect
    var mosaicSize: CGFloat
}
enum TextDragMode { case move, left, right }

final class HistorySlider: NSSlider {
    var beforeTracking: (() -> Void)?
    var afterTracking: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        beforeTracking?(); super.mouseDown(with: event); afterTracking?()
    }
}

final class AnnotationTextView: NSTextView {
    weak var editor: CaptureView?
    private let typingHistory = UndoManager()
    override var undoManager: UndoManager? { typingHistory }
    func handleHistoryKey(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "z",
              event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else { return false }
        if event.modifierFlags.contains(.shift) {
            if typingHistory.canRedo { typingHistory.redo() } else { editor?.redoMark() }
        } else {
            if typingHistory.canUndo { typingHistory.undo() } else { editor?.undoMark() }
        }
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleHistoryKey(event) { return true }
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            editor?.commitText(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if handleHistoryKey(event) { return }
        if event.keyCode == 53 || (event.keyCode == 36 && event.modifierFlags.contains(.command)) {
            editor?.commitText(); return
        }
        super.keyDown(with: event)
    }
}

extension CaptureView: NSTextViewDelegate {
    func snapshot() -> EditorState { EditorState(marks: marks, selection: selection, mosaicSize: mosaicSize) }
    func rememberChange(from before: EditorState) {
        guard before != snapshot() else { return }
        undoStates.append(before)
        if undoStates.count > 100 { undoStates.removeFirst() }
        redoStates.removeAll(); updateHistoryButtons()
    }
    func appendMark(_ mark: Mark) {
        let before = snapshot(); marks.append(mark); rememberChange(from: before)
    }
    func restore(_ state: EditorState) {
        discardTextEditor()
        marks = state.marks; selection = state.selection; mosaicSize = state.mosaicSize
        mosaicImage = nil; selectedTextIndex = nil; pending = nil
        UserDefaults.standard.set(Double(mosaicSize), forKey: "mosaicSize")
        if window != nil, !selection.isEmpty { showToolbar() }
        else if selection.isEmpty { dismissToolbar() }
        updateHistoryButtons(); needsDisplay = true; window?.makeFirstResponder(self)
    }
    @objc func undoMark() {
        commitText()
        guard let state = undoStates.popLast() else { return }
        redoStates.append(snapshot()); restore(state)
    }
    @objc func redoMark() {
        commitText()
        guard let state = redoStates.popLast() else { return }
        undoStates.append(snapshot()); restore(state)
    }
    func updateHistoryButtons() {
        undoButton?.isEnabled = !undoStates.isEmpty || textInput != nil
        redoButton?.isEnabled = !redoStates.isEmpty
    }
    func handleHistoryKey(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "z",
              event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else { return false }
        if event.modifierFlags.contains(.shift) { redoMark() } else { undoMark() }
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleHistoryKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    func textAttributes(for mark: Mark) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: 16 + mark.width * 2, weight: .semibold), .foregroundColor: mark.color, .paragraphStyle: paragraph]
    }
    func textRect(for mark: Mark) -> NSRect {
        let origin = mark.points.first ?? .zero
        let width = max(20, mark.textBoxWidth)
        let sample = mark.text.isEmpty ? "字" : mark.text + (mark.text.hasSuffix("\n") ? " " : "")
        let measured = (sample as NSString).boundingRect(with: NSSize(width: width, height: 100000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: textAttributes(for: mark))
        return NSRect(origin: origin, size: NSSize(width: width, height: max(28, ceil(measured.height) + 2)))
    }
    func textHandles(for rect: NSRect) -> [NSRect] {
        [NSRect(x: rect.minX - 5, y: rect.midY - 5, width: 10, height: 10),
         NSRect(x: rect.maxX - 5, y: rect.midY - 5, width: 10, height: 10)]
    }
    func drawTextSelection() {
        guard let index = selectedTextIndex, marks.indices.contains(index) else { return }
        let rect = textRect(for: marks[index])
        NSColor.systemGreen.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2)); path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0); path.stroke()
        for handle in textHandles(for: rect) {
            NSColor.white.setFill(); NSBezierPath(ovalIn: handle).fill()
            NSColor.systemGreen.setStroke(); NSBezierPath(ovalIn: handle).stroke()
        }
    }
    func beginTextInteraction(at point: NSPoint, clickCount: Int) -> Bool {
        guard tool == .select || tool == .text else { return false }
        if let index = selectedTextIndex, marks.indices.contains(index) {
            let handles = textHandles(for: textRect(for: marks[index]))
            if let side = handles.firstIndex(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) {
                startTextDrag(index: index, mode: side == 0 ? .left : .right, at: point); return true
            }
        }
        guard let index = marks.indices.reversed().first(where: { marks[$0].tool == .text && textRect(for: marks[$0]).insetBy(dx: -4, dy: -4).contains(point) }) else { return false }
        selectedTextIndex = index
        if clickCount >= 2 { editText(at: index) }
        else { startTextDrag(index: index, mode: .move, at: point) }
        return true
    }
    func startTextDrag(index: Int, mode: TextDragMode, at point: NSPoint) {
        selectedTextIndex = index; textDragMode = mode; textDragOriginal = marks[index]
        anchor = point; gestureBefore = snapshot()
    }
    func dragSelectedText(to point: NSPoint) {
        guard let index = selectedTextIndex, marks.indices.contains(index), let original = textDragOriginal, let mode = textDragMode else { return }
        let rect = textRect(for: original)
        var mark = original
        switch mode {
        case .move:
            mark.points = [NSPoint(x: min(max(rect.minX + point.x - anchor.x, selection.minX), max(selection.minX, selection.maxX - rect.width)),
                                   y: min(max(rect.minY + point.y - anchor.y, selection.minY), max(selection.minY, selection.maxY - rect.height)))]
        case .right:
            mark.textBoxWidth = min(max(40, rect.width + point.x - anchor.x), selection.maxX - rect.minX)
        case .left:
            let x = min(max(rect.minX + point.x - anchor.x, selection.minX), rect.maxX - 40)
            mark.points = [NSPoint(x: x, y: rect.minY)]; mark.textBoxWidth = rect.maxX - x
        }
        marks[index] = mark; needsDisplay = true
    }
    func beginText(at point: NSPoint) {
        commitText()
        let before = snapshot()
        let width = min(300, selection.width)
        let x = min(max(point.x, selection.minX), selection.maxX - width)
        let y = min(max(point.y, selection.minY), max(selection.minY, selection.maxY - 30))
        marks.append(Mark(tool: .text, points: [NSPoint(x: x, y: y)], color: ink, width: stroke, textBoxWidth: width))
        editText(at: marks.count - 1, before: before)
    }
    func editText(at index: Int, before: EditorState? = nil) {
        guard marks.indices.contains(index) else { return }
        textEditBefore = before ?? snapshot(); editingTextIndex = index; selectedTextIndex = index
        let mark = marks[index]
        let input = AnnotationTextView(frame: textRect(for: mark))
        input.editor = self; input.delegate = self; input.isRichText = false; input.allowsUndo = true
        input.drawsBackground = false; input.textContainerInset = .zero; input.textContainer?.lineFragmentPadding = 0
        input.isHorizontallyResizable = false; input.isVerticallyResizable = false
        input.textContainer?.widthTracksTextView = true
        input.textContainer?.containerSize = NSSize(width: mark.textBoxWidth, height: 100000)
        input.typingAttributes = textAttributes(for: mark)
        input.textStorage?.setAttributedString(NSAttributedString(string: mark.text, attributes: textAttributes(for: mark)))
        input.insertionPointColor = .systemGreen
        input.toolTip = "回车换行 · ⌘回车完成 · 完成后拖动文字移动，拖动两侧圆点调整换行"
        input.setAccessibilityLabel("截图文字标注，回车换行，Command加回车完成")
        addSubview(input); textInput = input
        resizeTextEditor(); window?.makeFirstResponder(input)
        input.setSelectedRange(NSRange(location: (mark.text as NSString).length, length: 0))
        updateHistoryButtons(); needsDisplay = true
    }
    func textDidChange(_ notification: Notification) {
        guard let index = editingTextIndex, marks.indices.contains(index), let input = textInput else { return }
        marks[index].text = input.string
        resizeTextEditor(); needsDisplay = true
    }
    func resizeTextEditor() {
        guard let index = editingTextIndex, marks.indices.contains(index), let input = textInput else { return }
        let rect = textRect(for: marks[index])
        input.frame = rect.intersection(selection)
        input.textContainer?.containerSize = NSSize(width: rect.width, height: 100000)
    }
    func discardTextEditor() {
        if textInput != nil { window?.makeFirstResponder(self) }
        textInput?.removeFromSuperview(); textInput = nil; editingTextIndex = nil; textEditBefore = nil
    }
    func commitText() {
        guard let index = editingTextIndex, marks.indices.contains(index), let input = textInput else { return }
        marks[index].text = input.string
        let before = textEditBefore
        if marks[index].text.isEmpty { marks.remove(at: index); selectedTextIndex = nil }
        discardTextEditor()
        if let before { rememberChange(from: before) }
        updateHistoryButtons(); needsDisplay = true; window?.invalidateCursorRects(for: self)
    }
}
