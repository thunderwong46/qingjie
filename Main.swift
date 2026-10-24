import AppKit
import Carbon
import ScreenCaptureKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var windows: [CaptureWindow] = []
    var capturing = false
    var paused = false
    var previousApp: NSRunningApplication?
    var alternate: Bool { UserDefaults.standard.bool(forKey: "alternateHotkey") }
    var shortcut: String { alternate ? "⌘⇧A" : "⌃S" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "轻截")
        status.button?.toolTip = "轻截 · \(shortcut) 截图"
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async { delegate.capture() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        registerHotkey()
        rebuildMenu()
        if CommandLine.arguments.contains("--enable-login") { enableLogin() }
        if CommandLine.arguments.contains("--verify-permission") {
            Task { @MainActor in
                let defaults = UserDefaults.standard
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    defaults.set("granted", forKey: "lastPermissionVerification")
                } catch {
                    let failure = error as NSError
                    defaults.set("\(failure.domain):\(failure.code)", forKey: "lastPermissionVerification")
                }
                defaults.set(Date().timeIntervalSince1970, forKey: "lastPermissionVerificationTime")
            }
        }
        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showWelcome() }
        }
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.demo() }
        }
    }

    func registerHotkey() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard !paused else { return }
        let code = alternate ? kVK_ANSI_A : kVK_ANSI_S
        let modifiers = alternate ? cmdKey | shiftKey : controlKey
        let result = RegisterEventHotKey(UInt32(code), UInt32(modifiers), EventHotKeyID(signature: 0x4C534854, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr {
            paused = true
            DispatchQueue.main.async { self.alert("快捷键注册失败", "可能已被其他工具占用。请从菜单栏切换快捷键，或关闭占用它的软件。") }
        }
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(item("截图  \(shortcut)", #selector(capture)))
        menu.addItem(.separator())
        let pause = item("暂停全局快捷键", #selector(togglePause)); pause.state = paused ? .on : .off; menu.addItem(pause)
        let key = item("改用 ⌘⇧A（默认 ⌃S）", #selector(toggleShortcut)); key.state = alternate ? .on : .off; menu.addItem(key)
        let login = item("登录后自动运行", #selector(toggleLogin)); login.state = SMAppService.mainApp.status == .enabled ? .on : .off; menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("屏幕录制权限…", #selector(openPermissions)))
        menu.addItem(item("使用说明", #selector(showWelcome)))
        menu.addItem(item("退出轻截", #selector(quit)))
        status.menu = menu
        status.button?.appearsDisabled = paused
        status.button?.toolTip = "轻截 · \(paused ? "快捷键已暂停" : shortcut + " 截图")"
    }
    @objc func togglePause() { paused.toggle(); registerHotkey(); rebuildMenu() }
    @objc func toggleShortcut() { UserDefaults.standard.set(!alternate, forKey: "alternateHotkey"); paused = false; registerHotkey(); rebuildMenu() }
    func enableLogin() {
        do {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { alert("自动启动未启用", error.localizedDescription + "\n可在菜单栏重新启用。") }
        rebuildMenu()
    }
    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            do { try SMAppService.mainApp.unregister() } catch { alert("无法关闭自动启动", error.localizedDescription) }
        } else { enableLogin() }
        rebuildMenu()
    }
    @objc func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc func showWelcome() {
        alert("轻截已在菜单栏运行", "按 \(shortcut) 开始截图，拖动框选，再选择标注工具。\n\n回车 / 双击：复制截图\nEsc / 右键：取消\n⌘Z / Ctrl+Z：撤销，⌘⇧Z：重做\n⌘⇧S：保存 PNG\n\n文字：回车换行，⌘回车完成。拖动文字移动，两侧圆点调整宽度，双击继续编辑。\n\n默认截图快捷键为 Control+S，可在菜单栏暂停或改用 ⌘⇧A。\n首次截图需要允许屏幕录制。图片仅在本机处理。")
    }
    func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "知道了"); alert.runModal()
    }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func capture() {
        guard !capturing, windows.isEmpty else { return }
        capturing = true
        previousApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            do {
                // Let the status-menu dismissal finish before freezing the desktop.
                try await Task.sleep(nanoseconds: 160_000_000)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                var captures: [(NSScreen, CGImage)] = []
                for screen in NSScreen.screens {
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = Int(screen.frame.width * screen.backingScaleFactor)
                    config.height = Int(screen.frame.height * screen.backingScaleFactor)
                    config.showsCursor = false
                    config.captureResolution = .best
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    captures.append((screen, image))
                }
                guard !captures.isEmpty else { throw NSError(domain: "轻截", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到可截图的显示器。请检查权限后重试。"]) }
                present(captures)
            } catch {
                let failure = error as NSError
                if failure.domain == SCStreamError.errorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue {
                    alert("系统尚未允许当前版本截图", "macOS 拒绝了这次屏幕访问。若设置中的「轻截」已打开，可能是应用更新后保留了旧版本的授权。\n\n请在屏幕录制设置中移除旧的「轻截」，再添加用户应用程序目录中的「轻截.app」并允许；按系统提示重新打开应用。")
                    openPermissions()
                } else {
                    alert("截图失败", "\(failure.localizedDescription)\n\n错误：\(failure.domain)（\(failure.code)）")
                }
                previousApp = nil
            }
            capturing = false
        }
    }
    func present(_ captures: [(NSScreen, CGImage)]) {
        NSApp.activate(ignoringOtherApps: true)
        for (screen, image) in captures {
            let window = CaptureWindow(screen: screen, image: image, owner: self)
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
    }
    func focus(_ chosen: CaptureWindow) {
        for window in windows where window !== chosen { window.orderOut(nil) }
        chosen.makeKey()
    }
    func finish() {
        for window in windows { window.editor.dismissToolbar(); window.orderOut(nil) }
        windows.removeAll()
        previousApp?.activate(options: [])
        previousApp = nil
    }
    func demo() {
        guard let screen = NSScreen.main else { return }
        let size = screen.frame.size
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.22, alpha: 1).setFill(); rect.fill()
            let card = NSRect(x: 130, y: 150, width: min(820, size.width - 200), height: 430)
            NSColor.white.setFill(); NSBezierPath(roundedRect: card, xRadius: 24, yRadius: 24).fill()
            ("轻截 · 框选你想留下的内容" as NSString).draw(at: NSPoint(x: 180, y: 210), withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.black])
            ("矩形  /  箭头  /  画笔  /  文字  /  马赛克\n\n标注完成，按回车复制。" as NSString).draw(at: NSPoint(x: 180, y: 290), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.darkGray])
            return true
        }
        var rect = NSRect(origin: .zero, size: size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) { present([(screen, cg)]) }
    }
}

@main struct LightShot {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        if CommandLine.arguments.contains("--self-test") {
            runSelfTests(owner: delegate)
            return
        }
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
