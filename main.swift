import Cocoa
import CoreGraphics
import ApplicationServices
import QuartzCore

// 视觉反馈高亮遮罩窗口
class FlashOverlayWindow: NSWindow {
    init(targetRect: NSRect) {
        super.init(contentRect: targetRect, styleMask: .borderless, backing: .buffered, defer: false)
        self.level = .screenSaver
        self.backgroundColor = .clear
        self.isOpaque = false
        self.ignoresMouseEvents = true
        self.hasShadow = true

        let container = NSView(frame: NSRect(origin: .zero, size: targetRect.size))
        container.wantsLayer = true

        guard let layer = container.layer else { return }
        layer.cornerRadius = 10
        layer.masksToBounds = true
        layer.borderWidth = 3.5
        // 苹果经典高亮蓝边框 + 柔和白光快照闪烁
        layer.borderColor = NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 0.95).cgColor
        layer.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.30).cgColor

        self.contentView = container
    }

    func playAnimation() {
        self.alphaValue = 1.0
        self.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 0.0
        }) {
            self.close()
        }
    }
}

class AntigravitySnapDaemon: NSObject {
    var globalMonitorFlags: Any?
    var globalMonitorKey: Any?
    var lastCmdPressTime: TimeInterval = 0
    var isCmdDown = false
    var isCapturing = false
    var isAntigravityActive = false
    var checkTimer: Timer?
    var shutterSound: NSSound?

    func start() {
        // 彻底静默：无任务栏图标、无菜单栏图标、无 Dock 图标
        NSApplication.shared.setActivationPolicy(.prohibited)

        // 预加载 macOS 原生快门音效
        let soundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if FileManager.default.fileExists(atPath: soundPath) {
            shutterSound = NSSound(contentsOfFile: soundPath, byReference: true)
        }

        let workspaceNC = NSWorkspace.shared.notificationCenter
        workspaceNC.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        workspaceNC.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        checkAntigravityStatus()

        // 轮询心跳检查，保障与 Antigravity 状态同步
        checkTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkAntigravityStatus()
        }
    }

    func isAntigravityProcess(_ app: NSRunningApplication) -> Bool {
        let name = app.localizedName ?? ""
        let bundleId = app.bundleIdentifier ?? ""
        return name == "Antigravity" || bundleId.contains("antigravity")
    }

    func checkAntigravityStatus() {
        let runningApps = NSWorkspace.shared.runningApplications
        let isRunning = runningApps.contains { isAntigravityProcess($0) }

        if isRunning && !isAntigravityActive {
            isAntigravityActive = true
            enableHotkeys()
        } else if !isRunning && isAntigravityActive {
            isAntigravityActive = false
            disableHotkeys()
        }
    }

    @objc func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if isAntigravityProcess(app) {
            checkAntigravityStatus()
        }
    }

    @objc func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if isAntigravityProcess(app) {
            checkAntigravityStatus()
        }
    }

    func enableHotkeys() {
        guard globalMonitorFlags == nil else { return }

        globalMonitorFlags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event: event)
        }

        globalMonitorKey = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.option, .command]) &&
               (event.charactersIgnoringModifiers?.lowercased() == "s" || event.keyCode == 1) {
                self?.triggerCapture()
            }
        }
    }

    func disableHotkeys() {
        if let monitor = globalMonitorFlags {
            NSEvent.removeMonitor(monitor)
            globalMonitorFlags = nil
        }
        if let monitor = globalMonitorKey {
            NSEvent.removeMonitor(monitor)
            globalMonitorKey = nil
        }
    }

    func handleFlagsChanged(event: NSEvent) {
        guard isAntigravityActive else { return }
        let isCmd = event.modifierFlags.contains(.command)
        let now = Date().timeIntervalSince1970

        if isCmd && !isCmdDown {
            isCmdDown = true
            if (now - lastCmdPressTime) < 0.35 && (now - lastCmdPressTime) > 0.05 {
                lastCmdPressTime = 0
                triggerCapture()
            } else {
                lastCmdPressTime = now
            }
        } else if !isCmd {
            isCmdDown = false
        }
    }

    func convertToCocoaRect(_ cgBounds: CGRect) -> NSRect {
        guard let mainScreen = NSScreen.screens.first else { return cgBounds }
        let screenHeight = mainScreen.frame.height
        let y = screenHeight - cgBounds.origin.y - cgBounds.height
        return NSRect(x: cgBounds.origin.x, y: y, width: cgBounds.width, height: cgBounds.height)
    }

    func triggerCapture() {
        guard isAntigravityActive && !isCapturing else { return }
        isCapturing = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isCapturing = false
            }
        }

        let target = getTargetWindow()

        // 1. 播放原生快门音效与窗口瞬闪动画
        DispatchQueue.main.async { [weak self] in
            self?.shutterSound?.stop()
            self?.shutterSound?.play()

            if let target = target {
                let cocoaRect = self?.convertToCocoaRect(target.bounds) ?? target.bounds
                let overlay = FlashOverlayWindow(targetRect: cocoaRect)
                overlay.playAnimation()
            }
        }

        // 2. 截取目标窗口到系统剪贴板
        if let target = target {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-l", String(target.wid), "-o", "-x", "-c"]
            try? task.run()
            task.waitUntilExit()
        } else {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-c"]
            try? task.run()
            task.waitUntilExit()
        }

        // 3. 唤醒并激活 Antigravity IDE 窗口
        let apps = NSWorkspace.shared.runningApplications
        guard let antigravity = apps.first(where: { isAntigravityProcess($0) }) else { return }

        if #available(macOS 14.0, *) {
            antigravity.activate()
        } else {
            antigravity.activate(options: [.activateIgnoringOtherApps])
        }

        // 4. 等待窗口切换平滑落地后，执行粘贴
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            let src = CGEventSource(stateID: .hidSystemState)
            let vKeyCode: CGKeyCode = 0x09 // 'v'

            let pasteDown = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true)
            pasteDown?.flags = .maskCommand
            let pasteUp = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false)
            pasteUp?.flags = .maskCommand

            pasteDown?.post(tap: .cghidEventTap)
            pasteUp?.post(tap: .cghidEventTap)
        }
    }

    func getTargetWindow() -> (wid: CGWindowID, owner: String, bounds: CGRect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let ignoredOwners = [
            "Antigravity", "Antigravity Helper", "Window Server",
            "WindowManager", "Notification Center", "Control Center",
            "SystemUIServer", "Dock"
        ]

        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            let wid = w[kCGWindowNumber as String] as? CGWindowID ?? 0
            let boundsDict = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let x = boundsDict["X"] as? CGFloat ?? 0
            let y = boundsDict["Y"] as? CGFloat ?? 0
            let width = boundsDict["Width"] as? CGFloat ?? 0
            let height = boundsDict["Height"] as? CGFloat ?? 0
            let bounds = CGRect(x: x, y: y, width: width, height: height)

            if layer == 0 && width > 150 && height > 150 && !ignoredOwners.contains(owner) {
                return (wid, owner, bounds)
            }
        }
        return nil
    }
}

let daemon = AntigravitySnapDaemon()
daemon.start()
RunLoop.main.run()
