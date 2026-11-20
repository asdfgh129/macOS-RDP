// anim_display.swift
// 在指定 displayID 上持续画动态彩条。
//
// 为什么需要：SCK 按「内容变化」送帧，虚拟屏上一片静止桌面时每秒只有 ~1 个
// complete 帧（其余是 idle），看起来像采集卡死。要给虚拟屏喂内容，窗口必须
// 落在**这块虚拟屏**上——按屏幕序号猜（NSScreen.main / 第一个 1920x1080）
// 会落到物理屏，物理屏被禁后窗口也没跟过去，这正是 2026-11-20 P2.2 1080p
// 三轮「采集崩溃」的误判来源。
//
// 用法：anim_display <displayID> [持续秒数，默认 120] [full]
//       传 0 表示当前主屏（CGMainDisplayID），镜像模式测试用。
//       第三个参数 full 表示铺满整屏（遮住窗口/壁纸，降低画面复杂度）。

import Cocoa

guard CommandLine.arguments.count > 1, let argID = UInt32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("用法: anim_display <displayID|0=主屏> [秒] [full]\n".data(using: .utf8)!)
    exit(2)
}
let targetID: UInt32 = argID == 0 ? CGMainDisplayID() : argID
let fullscreen = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "full"
let duration = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 120) : 120

class BarsView: NSView {
    var t: CGFloat = 0
    override func draw(_ dirty: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let n = 12
        let w = bounds.width / CGFloat(n)
        for i in 0..<n {
            let height = bounds.height * (0.2 + 0.7 * abs(sin(t + CGFloat(i) * 0.7)))
            NSColor(hue: CGFloat(i) / CGFloat(n), saturation: 0.8,
                    brightness: 0.95, alpha: 1).setFill()
            NSRect(x: CGFloat(i) * w, y: 0, width: w - 4, height: height).fill()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                   styleMask: [.borderless], backing: .buffered, defer: false)
win.level = .floating
win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
win.ignoresMouseEvents = true
let view = BarsView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
win.contentView = view

var shownOn: UInt32 = 0
let start = Date()
Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { timer in
    if Date().timeIntervalSince(start) > duration {
        timer.invalidate()
        app.terminate(nil)
        return
    }
    var target: NSScreen? = nil
    for s in NSScreen.screens {
        let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        if num == targetID { target = s; break }
    }
    guard let s = target else {
        if shownOn != 0 {
            win.orderOut(nil)
            shownOn = 0
            print("anim: display \(targetID) 已消失")
            fflush(stdout)
        }
        return
    }
    // 每 tick 重置位置：显示重排后窗口可能被留在旧屏上。
    let frame = fullscreen
        ? s.frame
        : NSRect(x: s.frame.midX - 600, y: s.frame.midY - 350, width: 1200, height: 700)
    win.setFrame(frame, display: true)
    view.frame = NSRect(origin: .zero, size: frame.size)
    if shownOn != targetID {
        win.orderFrontRegardless()
        shownOn = targetID
        print("anim: 窗口已贴到 display \(targetID) frame=\(s.frame)")
        fflush(stdout)
    }
    view.t += 0.15
    view.needsDisplay = true
}
app.run()
