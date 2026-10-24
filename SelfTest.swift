import AppKit

func runSelfTests(owner: AppDelegate) {
    var failures = 0
    func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL") \(name)")
        if !condition { failures += 1 }
    }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
    let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
    let green = NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)
    for y in 0..<600 {
        for x in 0..<800 {
            // Top half red, bottom half blue, a green strip at the far right.
            bitmap.setColor(x > 600 ? green : y < 150 ? red : blue, atX: x, y: y)
        }
    }
    let editor = CaptureView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), image: bitmap.cgImage!, owner: owner)
    editor.selection = NSRect(x: 50, y: 25, width: 100, height: 100)
    let data = editor.renderedPNG()!
    let output = NSBitmapImageRep(data: data)!
    check(output.pixelsWide == 200 && output.pixelsHigh == 200, "Retina crop has exact 200 × 200 dimensions")
    let top = output.colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
    let bottom = output.colorAt(x: 10, y: 190)!.usingColorSpace(.deviceRGB)!
    check(top.redComponent > 0.9 && top.blueComponent < 0.1, "Crop top retains original orientation and offset")
    check(bottom.blueComponent > 0.9 && bottom.redComponent < 0.1, "Crop bottom retains original orientation and offset")
    editor.appendMark(Mark(tool: .rectangle, points: [NSPoint(x: 70, y: 45), NSPoint(x: 130, y: 105)], color: .yellow, width: 4))
    let annotated = NSBitmapImageRep(data: editor.renderedPNG()!)!
    let edge = annotated.colorAt(x: 40, y: 80)!.usingColorSpace(.deviceRGB)!
    check(edge.redComponent > 0.9 && edge.greenComponent > 0.9 && edge.blueComponent < 0.1, "Annotation matches crop coordinates at Retina scale")
    editor.undoMark()
    let undone = NSBitmapImageRep(data: editor.renderedPNG()!)!
    let restored = undone.colorAt(x: 40, y: 80)!.usingColorSpace(.deviceRGB)!
    let baseline = output.colorAt(x: 40, y: 80)!.usingColorSpace(.deviceRGB)!
    check(editor.marks.isEmpty && abs(restored.greenComponent - baseline.greenComponent) < 0.01 && abs(restored.redComponent - baseline.redComponent) < 0.01 && abs(restored.blueComponent - baseline.blueComponent) < 0.01, "Undo restores the exact original pixel")
    editor.marks = Tool.allCases.filter { $0 != .select }.enumerated().map { index, tool in
        Mark(tool: tool, points: [NSPoint(x: 55 + index * 10, y: 35), NSPoint(x: 70 + index * 10, y: 90)], color: .yellow, width: 3, text: "测试")
    }
    check(editor.renderedPNG() != nil, "All six annotation tools render successfully")
    editor.marks = [Mark(tool: .mosaic, points: [NSPoint(x: 60, y: 55), NSPoint(x: 140, y: 110)], color: .black, width: 3)]
    editor.setMosaicSize(4, persist: false)
    let fineMosaic = editor.renderedPNG()!
    editor.setMosaicSize(40, persist: false)
    let coarseMosaic = editor.renderedPNG()!
    check(fineMosaic != coarseMosaic, "Fine and coarse mosaic produce different exported pixels")
    editor.setMosaicSize(4, persist: false)
    check(editor.renderedPNG() == fineMosaic, "Adjusting mosaic back restores the exact fine result")
    let mosaicOutput = NSBitmapImageRep(data: coarseMosaic)!
    check(mosaicOutput.colorAt(x: 5, y: 5) == output.colorAt(x: 5, y: 5), "Mosaic size does not change pixels outside its region")
    editor.reselect()
    check(editor.selection.isEmpty && editor.marks.isEmpty && editor.renderedPNG() == nil, "Reselect clears the old crop and annotations")
    let textEditor = CaptureView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), image: bitmap.cgImage!, owner: owner)
    textEditor.selection = textEditor.bounds
    textEditor.beginText(at: NSPoint(x: 40, y: 40))
    textEditor.textInput?.string = "拖动文字可以移动位置，调整文本框宽度可以自动换行。"
    textEditor.commitText()
    check(textEditor.marks.count == 1 && textEditor.undoStates.count == 1, "Committing text creates one undoable annotation")
    let initialText = textEditor.marks[0]
    let initialPNG = textEditor.renderedPNG()!
    textEditor.tool = .text
    check(textEditor.beginTextInteraction(at: NSPoint(x: 60, y: 50), clickCount: 1), "Existing text can be selected again")
    textEditor.dragSelectedText(to: NSPoint(x: 100, y: 80))
    textEditor.rememberChange(from: textEditor.gestureBefore!)
    textEditor.textDragMode = nil
    let movedPNG = textEditor.renderedPNG()!
    check(textEditor.marks[0].points[0] == NSPoint(x: 80, y: 70) && movedPNG != initialPNG, "Dragging text changes its position in exported PNG")
    textEditor.undoMark()
    check(textEditor.marks[0] == initialText && textEditor.renderedPNG() == initialPNG, "Undo text movement restores exact original text pixels")
    textEditor.redoMark()
    check(textEditor.renderedPNG() == movedPNG, "Redo restores the moved text")
    let wide = textEditor.textRect(for: textEditor.marks[0])
    textEditor.startTextDrag(index: 0, mode: .right, at: NSPoint(x: wide.maxX, y: wide.midY))
    textEditor.dragSelectedText(to: NSPoint(x: wide.minX + 160, y: wide.midY))
    textEditor.rememberChange(from: textEditor.gestureBefore!)
    textEditor.textDragMode = nil
    check(textEditor.marks[0].textBoxWidth == 160 && textEditor.textRect(for: textEditor.marks[0]).height > wide.height, "Narrowing text box automatically increases wrapped line count")
    textEditor.undoMark()
    check(textEditor.renderedPNG() == movedPNG, "Undo width adjustment restores original wrapping and export")
    textEditor.editText(at: 0)
    textEditor.textInput?.string = "第一行\n第二行"
    textEditor.commitText()
    check(textEditor.marks.count == 1 && textEditor.marks[0].text.contains("\n"), "Editing existing text preserves manual line breaks without duplication")
    textEditor.undoMark()
    check(textEditor.renderedPNG() == movedPNG, "Undo text edit restores previous content")
    let undoKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
    check(textEditor.performKeyEquivalent(with: undoKey) && textEditor.renderedPNG() == initialPNG, "Command-Z is handled through the key-equivalent path")
    textEditor.undoMark()
    check(textEditor.marks.isEmpty, "Further undo removes the inserted text")
    if let screen = NSScreen.main {
        let window = CaptureWindow(screen: screen, image: bitmap.cgImage!, owner: owner)
        window.editor.selection = NSRect(x: 100, y: 100, width: 600, height: 350)
        window.editor.showToolbar()
        if let view = window.editor.toolbar?.contentView {
            view.layoutSubtreeIfNeeded()
            check(view.bounds.width > 400 && view.bounds.width < 600 && view.bounds.height == 48, "Compact icon toolbar fits a single row")
            if let index = CommandLine.arguments.firstIndex(of: "--preview-output"), CommandLine.arguments.count > index + 1,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            }
        } else { check(false, "Toolbar is available") }
        window.editor.tool = .text
        window.editor.beginText(at: NSPoint(x: 150, y: 150))
        if let input = window.editor.textInput {
            input.insertText("可撤销输入", replacementRange: NSRange(location: NSNotFound, length: 0))
            check(!input.string.isEmpty && input.undoManager?.canUndo == true, "Native text input records typing history")
            check(window.performKeyEquivalent(with: undoKey) && input.string.isEmpty, "Command-Z while typing undoes text without cancelling the screenshot")
            input.string = "回车可以换行\n双击可继续编辑"
            window.editor.commitText()
            check(window.editor.undoButton?.isEnabled == true, "Visible Undo button enables after committing text")
            window.editor.undoMark()
            check(window.editor.marks.isEmpty && window.editor.redoButton?.isEnabled == true, "Undo button removes text and enables redo")
        } else { check(false, "Native text editor is available") }
        window.editor.tool = .mosaic
        window.editor.showPalette()
        check(window.editor.palette != nil, "Mosaic tool exposes its precision control")
        if let view = window.editor.palette?.contentView,
           let index = CommandLine.arguments.firstIndex(of: "--mosaic-preview-output"), CommandLine.arguments.count > index + 1 {
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            }
        }
        window.editor.dismissToolbar()
        window.orderOut(nil)
    }
    if let index = CommandLine.arguments.firstIndex(of: "--text-preview-output"), CommandLine.arguments.count > index + 1 {
        let size = NSSize(width: 640, height: 360)
        let white = NSImage(size: size, flipped: true) { rect in NSColor.white.setFill(); rect.fill(); return true }
        var rect = NSRect(origin: .zero, size: size)
        let preview = CaptureView(frame: rect, image: white.cgImage(forProposedRect: &rect, context: nil, hints: nil)!, owner: owner)
        preview.selection = NSRect(x: 30, y: 45, width: 580, height: 285)
        preview.appendMark(Mark(tool: .text, points: [NSPoint(x: 90, y: 95)], color: .black, width: 3, text: "这段文字可以拖动位置。缩窄文本框时，文字会自动换行。\n也支持手动换行。", textBoxWidth: 250))
        preview.selectedTextIndex = 0
        if let rep = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
            preview.cacheDisplay(in: preview.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
    }
    print("Tests completed: \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}
