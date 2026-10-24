import AppKit
import CoreImage

enum Tool: Int, CaseIterable {
    case select, rectangle, ellipse, arrow, pen, text, mosaic
    var title: String { ["移动", "矩形", "椭圆", "箭头", "画笔", "文字", "马赛克"][rawValue] }
}
struct Mark: Equatable {
    var tool: Tool
    var points: [NSPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
    var textBoxWidth: CGFloat = 240
    var rect: NSRect {
        let a = points.first ?? .zero, b = points.last ?? a
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

final class CaptureWindow: NSWindow {
    var editor: CaptureView!
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let input = firstResponder as? AnnotationTextView, input.handleHistoryKey(event) { return true }
        if firstResponder is AnnotationTextView { return super.performKeyEquivalent(with: event) }
        if editor?.handleHistoryKey(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    init(screen: NSScreen, image: CGImage, owner: AppDelegate) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = true; hasShadow = false; acceptsMouseMovedEvents = true
        editor = CaptureView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image, owner: owner)
        contentView = editor
        makeFirstResponder(editor)
    }
}

final class CaptureView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    let original: CGImage
    let background: NSImage
    weak var owner: AppDelegate?
    var selection = NSRect.zero
    var anchor = NSPoint.zero
    var initialSelection = NSRect.zero
    var selecting = false
    var moving = false
    var marks: [Mark] = []
    var pending: Mark?
    var tool = Tool.select
    var ink = NSColor.systemRed
    var stroke: CGFloat = 3
    var toolbar: NSPanel?
    var palette: NSPanel?
    var toolButtons: [NSButton] = []
    var colorButtons: [NSButton] = []
    var hint: NSTextField?
    var textInput: AnnotationTextView?
    var editingTextIndex: Int?
    var selectedTextIndex: Int?
    var textEditBefore: EditorState?
    var textDragMode: TextDragMode?
    var textDragOriginal: Mark?
    var gestureBefore: EditorState?
    var undoStates: [EditorState] = []
    var redoStates: [EditorState] = []
    var undoButton: NSButton?
    var redoButton: NSButton?
    var mosaicImage: NSImage?
    var mosaicSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "mosaicSize") as? Double ?? 18
        return CGFloat(min(40, max(4, saved)))
    }()
    lazy var imageContext = CIContext()
    let colors: [NSColor] = [.systemRed, .systemOrange, .systemBlue, .systemGreen, .white, .black]

    init(frame: NSRect, image: CGImage, owner: AppDelegate) {
        original = image
        background = NSImage(cgImage: image, size: frame.size)
        self.owner = owner
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: selection.isEmpty || tool != .select ? .crosshair : .openHand)
        if tool == .text || tool == .select {
            for mark in marks where mark.tool == .text { addCursorRect(textRect(for: mark).intersection(selection), cursor: .openHand) }
            if let index = selectedTextIndex, marks.indices.contains(index) {
                for handle in textHandles(for: textRect(for: marks[index])) { addCursorRect(handle.insetBy(dx: -4, dy: -4), cursor: .resizeLeftRight) }
            }
        }
    }
    func clamped(_ p: NSPoint) -> NSPoint { NSPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height)) }
    func point(_ e: NSEvent) -> NSPoint { clamped(convert(e.locationInWindow, from: nil)) }

    override func draw(_ dirtyRect: NSRect) {
        background.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.43).setFill()
        if selection.isEmpty { bounds.fill() } else {
            NSRect(x: 0, y: 0, width: bounds.width, height: selection.minY).fill()
            NSRect(x: 0, y: selection.maxY, width: bounds.width, height: bounds.height - selection.maxY).fill()
            NSRect(x: 0, y: selection.minY, width: selection.minX, height: selection.height).fill()
            NSRect(x: selection.maxX, y: selection.minY, width: bounds.width - selection.maxX, height: selection.height).fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            for (index, mark) in marks.enumerated() where index != editingTextIndex { draw(mark) }
            drawTextSelection()
            if let pending { draw(pending) }
            NSGraphicsContext.restoreGraphicsState()
            NSColor(calibratedRed: 0.2, green: 0.85, blue: 0.65, alpha: 1).setStroke()
            let border = NSBezierPath(rect: selection); border.lineWidth = 1.5; border.stroke()
            let scale = CGFloat(original.width) / bounds.width
            let dimensions = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded()))"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
            let size = (dimensions as NSString).size(withAttributes: attrs)
            let label = NSRect(x: selection.minX, y: max(4, selection.minY - 28), width: size.width + 16, height: 23)
            NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: label, xRadius: 5, yRadius: 5).fill()
            (dimensions as NSString).draw(at: NSPoint(x: label.minX + 8, y: label.minY + 4), withAttributes: attrs)
        }
        if selection.isEmpty {
            let text = "拖动框选截图区域   ·   Esc / 右键取消"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.white]
            let size = (text as NSString).size(withAttributes: attrs)
            let rect = NSRect(x: (bounds.width - size.width) / 2 - 24, y: 70, width: size.width + 48, height: 48)
            NSColor.black.withAlphaComponent(0.75).setFill(); NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            (text as NSString).draw(at: NSPoint(x: rect.minX + 24, y: rect.minY + 14), withAttributes: attrs)
        }
    }

    func draw(_ mark: Mark) {
        guard let a = mark.points.first, let b = mark.points.last else { return }
        mark.color.setStroke(); mark.color.setFill()
        let path = NSBezierPath(); path.lineWidth = mark.width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        switch mark.tool {
        case .rectangle: path.appendRect(mark.rect); path.stroke()
        case .ellipse: path.appendOval(in: mark.rect); path.stroke()
        case .arrow:
            path.move(to: a); path.line(to: b); path.stroke()
            let angle = atan2(b.y - a.y, b.x - a.x), length = max(13, mark.width * 4)
            let head = NSBezierPath(); head.move(to: b)
            head.line(to: NSPoint(x: b.x - length * cos(angle - .pi / 7), y: b.y - length * sin(angle - .pi / 7)))
            head.line(to: NSPoint(x: b.x - length * cos(angle + .pi / 7), y: b.y - length * sin(angle + .pi / 7)))
            head.close(); head.fill()
        case .pen:
            path.move(to: a)
            if mark.points.count == 1 { path.line(to: NSPoint(x: a.x + 0.1, y: a.y)) }
            for p in mark.points.dropFirst() { path.line(to: p) }; path.stroke()
        case .text:
            (mark.text as NSString).draw(with: textRect(for: mark), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: textAttributes(for: mark), context: nil)
        case .mosaic:
            if mosaicImage == nil {
                let source = CIImage(cgImage: original)
                let filtered = source.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: mosaicSize * CGFloat(original.width) / bounds.width])
                if let image = imageContext.createCGImage(filtered, from: source.extent) { mosaicImage = NSImage(cgImage: image, size: bounds.size) }
            }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: mark.rect).addClip()
            NSGraphicsContext.current?.imageInterpolation = .none
            mosaicImage?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        case .select: break
        }
    }

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let p = point(event)
        if selection.isEmpty {
            anchor = p; selecting = true
            if let window = window as? CaptureWindow { owner?.focus(window) }
        } else if selection.contains(p) {
            if beginTextInteraction(at: p, clickCount: event.clickCount) { needsDisplay = true; return }
            selectedTextIndex = nil
            if event.clickCount == 2 && tool != .text { copyImage(); return }
            anchor = p
            if tool == .select { gestureBefore = snapshot(); moving = true; initialSelection = selection; toolbar?.orderOut(nil); palette?.orderOut(nil) }
            else if tool == .text { beginText(at: p) }
            else { pending = Mark(tool: tool, points: [p], color: ink, width: stroke) }
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if textDragMode != nil { dragSelectedText(to: p); needsDisplay = true; return }
        if selecting { selection = Mark(tool: .select, points: [anchor, p], color: ink, width: stroke).rect }
        else if moving {
            let x = min(max(initialSelection.minX + p.x - anchor.x, 0), bounds.width - selection.width)
            let y = min(max(initialSelection.minY + p.y - anchor.y, 0), bounds.height - selection.height)
            selection.origin = NSPoint(x: x, y: y)
        } else if pending != nil {
            let bounded = NSPoint(x: min(max(p.x, selection.minX), selection.maxX), y: min(max(p.y, selection.minY), selection.maxY))
            if tool == .pen { pending?.points.append(bounded) }
            else { pending?.points = [anchor, bounded] }
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if textDragMode != nil {
            if let before = gestureBefore { rememberChange(from: before) }
            textDragMode = nil; textDragOriginal = nil; gestureBefore = nil
            needsDisplay = true; return
        }
        if selecting {
            selecting = false
            if selection.width < 4 || selection.height < 4 { selection = .zero }
            else {
                // Snap to pixel boundaries so the dimensions match the exported PNG.
                let sx = CGFloat(original.width) / bounds.width, sy = CGFloat(original.height) / bounds.height
                let x = floor(selection.minX * sx) / sx, y = floor(selection.minY * sy) / sy
                selection = NSRect(x: x, y: y, width: ceil(selection.maxX * sx) / sx - x, height: ceil(selection.maxY * sy) / sy - y).intersection(bounds)
                showToolbar()
            }
        }
        if moving { moving = false; if let before = gestureBefore { rememberChange(from: before) }; gestureBefore = nil; showToolbar() }
        if let pending {
            if pending.tool == .pen || pending.rect.width > 1 || pending.rect.height > 1 { appendMark(pending) }
            self.pending = nil
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
    override func rightMouseDown(with event: NSEvent) { cancel() }

    func button(_ title: String, action: Selector, tag: Int = 0) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.tag = tag; b.bezelStyle = .rounded; b.font = .systemFont(ofSize: 12)
        return b
    }
    func iconButton(_ symbol: String, title: String, action: Selector, tag: Int = 0) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
        b.tag = tag; b.isBordered = false; b.imagePosition = .imageOnly
        b.image = b.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        b.contentTintColor = NSColor(white: 0.23, alpha: 1)
        b.toolTip = title; b.setAccessibilityLabel(title)
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return b
    }
    func floatingPanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.appearance = NSAppearance(named: .aqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.99, alpha: 1).cgColor
        background.layer?.cornerRadius = 8
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor(white: 0.84, alpha: 1).cgColor
        panel.contentView = background
        return panel
    }
    func separator() -> NSView {
        let view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = NSColor(white: 0.88, alpha: 1).cgColor
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return view
    }
    func showToolbar() {
        dismissToolbar()
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 5; row.alignment = .centerY
        let entries: [(Tool, String)] = [(.rectangle, "rectangle"), (.ellipse, "circle"), (.arrow, "arrow.up.right"), (.pen, "pencil.tip"), (.mosaic, "checkerboard.rectangle"), (.text, "t.square")]
        for (tool, symbol) in entries {
            let b = iconButton(symbol, title: tool.title, action: #selector(chooseTool(_:)), tag: tool.rawValue)
            b.setButtonType(.toggle); b.state = tool == self.tool ? .on : .off
            b.contentTintColor = tool == self.tool ? .systemGreen : NSColor(white: 0.23, alpha: 1)
            toolButtons.append(b); row.addArrangedSubview(b)
        }
        row.addArrangedSubview(separator())
        let undo = button("撤销", action: #selector(undoMark))
        undo.isBordered = false
        undo.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "撤销")
        undo.imagePosition = .imageLeading; undo.toolTip = "撤销（⌘Z / Ctrl+Z）"
        undo.widthAnchor.constraint(equalToConstant: 62).isActive = true
        undoButton = undo; row.addArrangedSubview(undo)
        let redo = iconButton("arrow.uturn.forward", title: "重做（⌘⇧Z）", action: #selector(redoMark))
        redoButton = redo; row.addArrangedSubview(redo)
        updateHistoryButtons()
        row.addArrangedSubview(iconButton("crop", title: "重新框选", action: #selector(reselect)))
        row.addArrangedSubview(iconButton("arrow.down.to.line", title: "保存（⌘⇧S）", action: #selector(saveImage)))
        row.addArrangedSubview(separator())
        let cancel = iconButton("xmark", title: "取消（Esc）", action: #selector(cancel)); cancel.contentTintColor = .systemRed; row.addArrangedSubview(cancel)
        let copy = iconButton("checkmark", title: "完成并复制（回车）", action: #selector(copyImage)); copy.contentTintColor = .systemGreen; row.addArrangedSubview(copy)
        let size = NSSize(width: row.fittingSize.width + 16, height: 48)
        let panel = floatingPanel(size: size)
        row.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 8), row.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor)])
        guard let window else { return }
        let lowerLeft = window.convertPoint(toScreen: NSPoint(x: selection.minX, y: bounds.height - selection.maxY))
        var y = lowerLeft.y - panel.frame.height - 10
        if y < window.frame.minY + 8 { y = window.frame.minY + bounds.height - selection.minY + 10 }
        y = min(max(y, window.frame.minY + 8), window.frame.maxY - panel.frame.height - 8)
        let x = min(max(lowerLeft.x, window.frame.minX + 8), window.frame.maxX - panel.frame.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        window.addChildWindow(panel, ordered: .above); panel.orderFront(nil); toolbar = panel
        if tool != .select { showPalette() }
    }
    func showPalette() {
        dismissPalette()
        guard tool != .select, let toolbar, let window else { return }
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 4; row.alignment = .centerY
        if tool == .mosaic {
            let title = NSTextField(labelWithString: "颗粒")
            title.font = .systemFont(ofSize: 12)
            row.addArrangedSubview(title)
            row.addArrangedSubview(NSTextField(labelWithString: "细"))
            let slider = HistorySlider(value: Double(mosaicSize), minValue: 4, maxValue: 40, target: self, action: #selector(changeMosaicSize(_:)))
            slider.isContinuous = true
            slider.beforeTracking = { [weak self] in self?.gestureBefore = self?.snapshot() }
            slider.afterTracking = { [weak self] in
                guard let self else { return }
                if let before = self.gestureBefore { self.rememberChange(from: before) }
                self.gestureBefore = nil
            }
            slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
            slider.toolTip = "调整本次截图所有马赛克的颗粒大小，并记住下次使用"
            slider.setAccessibilityLabel("马赛克颗粒大小，向右变粗")
            row.addArrangedSubview(slider)
            row.addArrangedSubview(NSTextField(labelWithString: "粗"))
        } else {
        for (index, color) in colors.enumerated() {
            let b = button("●", action: #selector(chooseColor(_:)), tag: index)
            b.isBordered = false; b.contentTintColor = color; b.setButtonType(.toggle); b.state = color == ink ? .on : .off
            b.font = .systemFont(ofSize: 21); b.widthAnchor.constraint(equalToConstant: 27).isActive = true
            b.toolTip = ["红色", "橙色", "蓝色", "绿色", "白色", "黑色"][index]
            b.setAccessibilityLabel(b.toolTip!)
            colorButtons.append(b); row.addArrangedSubview(b)
        }
        row.addArrangedSubview(separator())
        let width = NSPopUpButton(); width.addItems(withTitles: ["细", "中", "粗"]); width.selectItem(at: stroke == 2 ? 0 : stroke == 3 ? 1 : 2)
        width.target = self; width.action = #selector(changeWidth(_:)); width.toolTip = "标注粗细"; row.addArrangedSubview(width)
        }
        let panel = floatingPanel(size: NSSize(width: row.fittingSize.width + 16, height: 38))
        row.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 8), row.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor)])
        var y = toolbar.frame.minY - 44
        if y < window.frame.minY + 8 { y = toolbar.frame.maxY + 6 }
        panel.setFrameOrigin(NSPoint(x: toolbar.frame.minX, y: min(y, window.frame.maxY - 46)))
        window.addChildWindow(panel, ordered: .above); panel.orderFront(nil); palette = panel
    }
    func dismissPalette() {
        if let palette { window?.removeChildWindow(palette); palette.orderOut(nil) }
        palette = nil; colorButtons = []
    }
    func dismissToolbar() {
        dismissPalette()
        if let toolbar { window?.removeChildWindow(toolbar); toolbar.orderOut(nil) }
        toolbar = nil; toolButtons = []
    }
    @objc func chooseTool(_ sender: NSButton) {
        commitText()
        let chosen = Tool(rawValue: sender.tag) ?? .select
        tool = chosen == tool ? .select : chosen
        if tool != .text && tool != .select { selectedTextIndex = nil; needsDisplay = true }
        for b in toolButtons {
            b.state = b.tag == tool.rawValue ? .on : .off
            b.contentTintColor = b.tag == tool.rawValue ? .systemGreen : NSColor(white: 0.23, alpha: 1)
        }
        showPalette()
        window?.makeFirstResponder(self); window?.invalidateCursorRects(for: self)
    }
    @objc func chooseColor(_ sender: NSButton) {
        commitText(); ink = colors[sender.tag]
        if let index = selectedTextIndex, marks.indices.contains(index) {
            let before = snapshot(); marks[index].color = ink; rememberChange(from: before); needsDisplay = true
        }
        for b in colorButtons { b.state = b.tag == sender.tag ? .on : .off }
        window?.makeFirstResponder(self)
    }
    @objc func changeWidth(_ sender: NSPopUpButton) {
        commitText(); stroke = [2.0, 3.0, 6.0][sender.indexOfSelectedItem]
        if let index = selectedTextIndex, marks.indices.contains(index) {
            let before = snapshot(); marks[index].width = stroke; rememberChange(from: before); needsDisplay = true
        }
        window?.makeFirstResponder(self)
    }
    func setMosaicSize(_ value: Double, persist: Bool = true) {
        let size = CGFloat(min(40, max(4, value.rounded())))
        guard size != mosaicSize else { return }
        mosaicSize = size
        mosaicImage = nil
        if persist { UserDefaults.standard.set(Double(size), forKey: "mosaicSize") }
        needsDisplay = true
    }
    @objc func changeMosaicSize(_ sender: NSSlider) {
        setMosaicSize(sender.doubleValue)
    }
    @objc func reselect() {
        commitText(); let before = snapshot(); marks.removeAll(); selection = .zero; selectedTextIndex = nil
        rememberChange(from: before); tool = .select; dismissToolbar(); needsDisplay = true; window?.makeFirstResponder(self)
    }
    @objc func cancel() { owner?.finish() }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if handleHistoryKey(event) { return }
        if event.keyCode == 53 {
            if selectedTextIndex != nil { selectedTextIndex = nil; needsDisplay = true } else { cancel() }
        }
        else if event.keyCode == 36 || event.keyCode == 76 || (cmd && key == "c") { copyImage() }
        else if cmd && shift && key == "s" { saveImage() }
        else if (event.keyCode == 51 || event.keyCode == 117), let index = selectedTextIndex, marks.indices.contains(index) {
            let before = snapshot(); marks.remove(at: index); selectedTextIndex = nil; rememberChange(from: before); needsDisplay = true
        }
        else { super.keyDown(with: event) }
    }

    func renderedPNG() -> Data? {
        commitText()
        guard !selection.isEmpty else { return nil }
        let sx = CGFloat(original.width) / bounds.width, sy = CGFloat(original.height) / bounds.height
        let width = Int((selection.width * sx).rounded()), height = Int((selection.height * sy).rounded())
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let cg = context.cgContext
        cg.translateBy(x: 0, y: CGFloat(height)); cg.scaleBy(x: sx, y: -sy); cg.translateBy(x: -selection.minX, y: -selection.minY)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        background.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        for mark in marks { draw(mark) }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
    @objc func copyImage() {
        guard let data = renderedPNG() else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general; pasteboard.clearContents()
        let item = NSPasteboardItem(); item.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        guard pasteboard.writeObjects([item]) else { hint?.stringValue = "复制失败，请重试或保存图片"; return }
        owner?.finish()
    }
    @objc func saveImage() {
        guard let data = renderedPNG() else { NSSound.beep(); return }
        // Drop the overlay below the standard save dialog while it is open.
        toolbar?.orderOut(nil); palette?.orderOut(nil); window?.orderOut(nil)
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.canCreateDirectories = true
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "截图 \(format.string(from: Date())).png"
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url, options: .atomic); owner?.finish(); return }
            catch { owner?.alert("保存失败", error.localizedDescription) }
        }
        window?.makeKeyAndOrderFront(nil); toolbar?.orderFront(nil); palette?.orderFront(nil); window?.makeFirstResponder(self)
    }
}
