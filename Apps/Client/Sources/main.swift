//
//  main.swift
//  VeilRD client
//
//  产品入口（第 3 轮）：Swift 主 + ObjC 桥，消费 RDPKit / ProtocolCodec 静态库。
//  --selftest 跑纯逻辑自检（配对 / 会话 / 输入 / 解码预热 / 上屏视图构造）；
//  默认输出 D-02 桥接演示。真实窗口与 QUIC 收流仍在 stream_probe，后续并入本入口。
//

import Foundation
import AppKit

// MARK: - Swift 实现的会话驱动（mock，验证 Swift → ObjC protocol 桥接）

@objc final class SwiftMockDriver: NSObject, M1SessionDriver {
    private(set) var calls: [String] = []

    func acquireSleepAssertion(_ error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        calls.append("sleep+"); return true
    }
    func releaseSleepAssertion() { calls.append("sleep-") }
    func createVirtualDisplays(_ specs: [[AnyHashable: Any]], error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        calls.append("create"); return true
    }
    func replaceVirtualDisplays(_ specs: [[AnyHashable: Any]], error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        calls.append("replace"); return true
    }
    func createdDisplayIDs() -> [NSNumber] { return [101, 102] }
    func snapshotAndDisablePhysicalExcept(_ keepIDs: [NSNumber], error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        calls.append("disable"); return true
    }
    func verifyIsolation(_ error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        calls.append("isolate"); return true
    }
    func injectUnlockCredential(_ credential: String, error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        calls.append("inject"); return true
    }
    func restorePhysicalAndDestroyDisplays(_ error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        calls.append("restore"); return true
    }
    func lockScreen(_ error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        calls.append("lock"); return true
    }
}

// MARK: - 演示

func banner(_ s: String) { print("\n=== \(s) ===") }

func demoPairing() {
    banner("配对 / TOFU（ObjC 纯逻辑，Swift 调用）")
    let state = M1PairingState(store: M1InMemoryPairingStore())
    let now = Date().timeIntervalSince1970
    let code = state.issueCode(atTime: now)
    print("签发配对码: \(code) (6位=\(M1IsValidPairingCode(code)))")
    let fp = String(repeating: "ab", count: 32) // 64 hex
    var bound: String?
    do { bound = try state.confirm(code: code, fingerprint: fp, atTime: now + 1) } catch {}
    print("配对成功: \(bound != nil), isPaired=\(state.isPaired)")
    var okSame = false, okBad = true
    do { try state.verify(fingerprint: fp); okSame = true } catch {}
    let fpBad = String(repeating: "cd", count: 32)
    do { try state.verify(fingerprint: fpBad); okBad = true } catch { okBad = false }
    print("TOFU 一致=\(okSame), 变更拒绝=\(!okBad)")
}

func demoTakeover() {
    banner("现场接管手势（ObjC 纯逻辑，Swift 驱动）")
    let det = M1TakeoverDetector()
    let t = Date().timeIntervalSince1970
    _ = det.handle(signal: .shiftDown, atTime: t)
    _ = det.tick(atTime: t + 3.1)
    print("Shift 按住 3.1s → pendingDisconnect=\(det.pendingDisconnect)")
    let v = det.handle(signal: .hotplug, atTime: t + 3.2)
    print("热插拔 fail-safe → verdict=\(v.rawValue) (4=ForceDisconnect)")
}

func demoSession() {
    banner("会话生命周期（Swift 实现 ObjC protocol → ObjC 协调器）")
    let driver = SwiftMockDriver()
    let coord = M1SessionCoordinator(driver: driver)
    let specs: [[AnyHashable: Any]] = [["width": 1920, "height": 1080]]
    var started = false
    do { try coord.start(specs: specs, needsLogin: false, credential: nil); started = true } catch {}
    print("start=\(started), phase=\(M1HostSessionPhaseName(coord.phase))")
    print("调用序列: \(driver.calls.joined(separator: " → "))")
    _ = try? coord.endSession()
    print("end 后 phase=\(M1HostSessionPhaseName(coord.phase))")
    print("完整序列: \(driver.calls.joined(separator: " → "))")
}

func demoInputAndIsolation() {
    banner("输入计划 / C-09 隔离（ObjC 纯函数，Swift 调用）")
    let rect = CGRect(x: 100, y: 200, width: 1920, height: 1080)
    var planErr: NSError?
    let plan = injectionPlan(event: ["kind": "mouse", "displayID": 101,
                                "x": 0.5, "y": 0.5, "button": "left",
                                "action": "down", "flags": ["shift": 1]] as [AnyHashable: Any],
                               targetRect: rect, &planErr)
    print("鼠标计划: \(plan?.description ?? "nil")")
    let leaked = isolationLeakedDisplays(active: [101, 102, 999], sessionVirtuals: [101, 102])
    print("C-09 泄漏物理屏: \(leaked?.description ?? "none（隔离干净）")")
    let seq = credentialEventSequence("中")
    print("中文凭据事件数=\(seq.count) (含 Return)")
}

func demoRenderPipeline() {
    banner("渲染 / 解码（RDPKit 真实模块）")
    M1FrameReceiver.prewarmDecoder()
    let fitted = aspectFitRect(videoSize: CGSize(width: 1920, height: 1080),
                               bounds: CGRect(x: 0, y: 0, width: 1280, height: 720))
    let view = M1FrameView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
    let p = normalizedPoint(fromViewPoint: CGPoint(x: fitted.midX, y: fitted.minY),
                            videoRect: fitted)
    print("解码器预热完成；letterbox=\(fitted)；上屏视图=\(type(of: view))；归一化点=(\(p.x), \(p.y))")
}

func runSelftest() -> Bool {
    let state = M1PairingState(store: M1InMemoryPairingStore())
    let now = Date().timeIntervalSince1970
    let code = state.issueCode(atTime: now)
    guard M1IsValidPairingCode(code) else { return false }

    let driver = SwiftMockDriver()
    let coord = M1SessionCoordinator(driver: driver)
    var started = false
    do { try coord.start(specs: [["width": 1280, "height": 720]], needsLogin: false, credential: nil); started = true } catch {}
    guard started else { return false }
    _ = try? coord.endSession()
    guard M1HostSessionPhaseName(coord.phase).contains("Idle") ||
          M1HostSessionPhaseName(coord.phase).contains("Locked") else { return false }

    let flag = eventFlags(fromDict: ["shift": 1, "cmd": 1])
    let viewRect = aspectFitRect(videoSize: CGSize(width: 1920, height: 1080),
                                 bounds: CGRect(x: 0, y: 0, width: 1280, height: 720))
    guard viewRect.width > 0, flag != 0 else { return false }

    M1FrameReceiver.prewarmDecoder()
    let view = M1FrameView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    guard view.frame.width == 320 else { return false }
    print("VeilRD client selftest PASS")
    return true
}

// MARK: - --connect：真实 QUIC 收流 / 上屏 / 输入回传

func parseSize(_ s: String) -> (Int, Int)? {
    let parts = s.split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
    return (w, h)
}

/// 一块远程屏在本地的窗口/视图。
final class DisplaySlot {
    let window: NSWindow
    let view: M1FrameView
    var displayID: UInt32 = 0
    var inputSent = 0
    var inputFailed = 0
    var savedFrame: NSRect?

    init(window: NSWindow, view: M1FrameView) {
        self.window = window
        self.view = view
    }
}

/// 帧队列（每屏一条）→ 主线程视图的路由。帧可能在绑定 displayID 之前到达，
/// 单屏时按唯一视图兜底，多屏时丢弃未绑定屏的帧（下一帧即可补上）。
final class DisplayRouter {
    private let lock = NSLock()
    private var views: [UInt32: M1FrameView] = [:]

    func bind(_ view: M1FrameView, displayID: UInt32) {
        lock.lock()
        views[displayID] = view
        lock.unlock()
    }

    func view(for displayID: UInt32) -> M1FrameView? {
        lock.lock()
        defer { lock.unlock() }
        if let v = views[displayID] { return v }
        return views.count == 1 ? views.values.first : nil
    }

    /// 换屏后旧 displayID 的绑定必须清掉，否则旧屏迟到帧会往已关闭的窗口上贴。
    func reset() {
        lock.lock()
        views.removeAll()
        lock.unlock()
    }
}

func runConnect() -> Int32 {
    let args = CommandLine.arguments
    func arg(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    func argValues(_ name: String) -> [String] {
        var out: [String] = []
        var i = 0
        while i + 1 < args.count {
            if args[i] == name { out.append(args[i + 1]); i += 2 } else { i += 1 }
        }
        return out
    }
    guard let connectHost = arg("--connect"),
          let portText = arg("--port"), let port = UInt16(portText),
          let fingerprint = arg("--fingerprint") else {
        print("✗ --connect 需要 --connect IP --port N --fingerprint HEX")
        return 1
    }
    let durationMs = Int(arg("--duration-ms") ?? "5000") ?? 5000
    let waitMs = UInt32(arg("--wait-ms") ?? "15000") ?? 15000
    let handshakeMs = UInt32(arg("--handshake-ms") ?? "12000") ?? 12000
    let saveFrames = Int(arg("--save-frames") ?? "5") ?? 5
    let outdir = arg("--outdir") ?? ""
    let outPath = arg("--out")

    // 多屏：--spec 可重复（也接受逗号分隔），每块屏一个窗口。
    let specs: [(Int, Int)] = argValues("--spec")
        .flatMap { $0.split(separator: ",").map(String.init) }
        .compactMap { parseSize($0) }
    let windowSizes: [(Int, Int)] = argValues("--window")
        .flatMap { $0.split(separator: ",").map(String.init) }
        .compactMap { parseSize($0) }
    let displayCount = max(specs.count, 1)
    let defaultWindow = windowSizes.first ?? (1280, 720)
    func windowSize(_ index: Int) -> (Int, Int) {
        windowSizes.isEmpty ? defaultWindow : windowSizes[min(index, windowSizes.count - 1)]
    }

    // FR-07：会话中换屏。--update-at 毫秒（可重复/逗号分隔），--update-spec 为新的整套规格。
    let updateAtMs: [Int] = argValues("--update-at")
        .flatMap { $0.split(separator: ",").map(String.init) }
        .compactMap { Int($0) }
    let updateSpecs: [(Int, Int)] = argValues("--update-spec")
        .flatMap { $0.split(separator: ",").map(String.init) }
        .compactMap { parseSize($0) }
    // FR-06 诊断：--send-text 毫秒:文本（可重复），按 IME 提交后的同一事件上行。
    let sendTexts: [(Int, String)] = argValues("--send-text").compactMap { pair in
        guard let i = pair.firstIndex(of: ":"), let ms = Int(pair[..<i]) else { return nil }
        return (ms, String(pair[pair.index(after: i)...]))
    }

    M1FrameReceiver.prewarmDecoder()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    var closedByUser = false
    func makeSlot(_ index: Int, _ size: (Int, Int)) -> DisplaySlot {
        let content = NSRect(x: 0, y: 0, width: size.0, height: size.1)
        let window = NSWindow(contentRect: content,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "VeilRD \(index + 1)/\(displayCount) \(size.0)×\(size.1)（Esc 退出）"
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        let view = M1FrameView(frame: content)
        window.contentView = view
        window.center()
        if index > 0 {
            window.setFrameOrigin(NSPoint(x: window.frame.origin.x + CGFloat(index * 40),
                                          y: window.frame.origin.y - CGFloat(index * 40)))
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { _ in
            closedByUser = true
            NSApp.stop(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return DisplaySlot(window: window, view: view)
    }

    var slots: [DisplaySlot] = (0..<displayCount).map { makeSlot($0, windowSize($0)) }
    let router = DisplayRouter()
    let client = M1StreamClientNode()

    // FR-06 沉浸模式：窗口铺满各自屏幕、自动隐藏 Dock/菜单栏；Cmd+Opt+F 切换。
    var immersive = false
    func applyImmersive(_ on: Bool) {
        guard on != immersive else { return }
        immersive = on
        NSApp.presentationOptions = on ? [.autoHideDock, .autoHideMenuBar] : []
        let screens = NSScreen.screens
        for (i, slot) in slots.enumerated() {
            if on {
                slot.savedFrame = slot.window.frame
                slot.window.styleMask = [.borderless]
                if !screens.isEmpty {
                    slot.window.setFrame(screens[min(i, screens.count - 1)].frame, display: true)
                }
                slot.window.makeKeyAndOrderFront(nil)
            } else {
                slot.window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                if let f = slot.savedFrame { slot.window.setFrame(f, display: true) }
            }
        }
        print("沉浸模式 \(on ? "开" : "关")（Cmd+Opt+F 切换）")
    }

    // 把窗口/路由/输入重绑到给定屏表；allowShrink 时关闭多出来的窗口（换屏缩屏用）。
    func bindSlots(_ displays: [[AnyHashable: Any]], allowShrink: Bool) {
        let n = displays.count
        while slots.count < n {
            slots.append(makeSlot(slots.count, windowSize(slots.count)))
        }
        for (i, display) in displays.enumerated() {
            guard i < slots.count, let id = display["displayID"] as? NSNumber else { continue }
            let displayID = id.uint32Value
            slots[i].displayID = displayID
            slots[i].view.displayID = displayID
            router.bind(slots[i].view, displayID: displayID)
            let w = (display["w"] as? NSNumber)?.intValue ?? Int(slots[i].window.frame.width)
            let h = (display["h"] as? NSNumber)?.intValue ?? Int(slots[i].window.frame.height)
            slots[i].window.title = "VeilRD \(i + 1)/\(n) \(w)×\(h)（Esc 退出）"
            print("窗口 \(i + 1) → displayID=\(displayID)（\(w)×\(h)）")
        }
        if allowShrink && slots.count > n {
            for slot in slots[n...] { slot.window.orderOut(nil) }
            slots.removeSubrange(n...)
        }
        for slot in slots { wireSlot(slot) }
    }

    client.expectedFingerprint = fingerprint
    client.outdir = outdir
    client.saveFrames = UInt(saveFrames)
    if !specs.isEmpty {
        client.requestedSpecs = specs.map {
            ["w": $0.0, "h": $0.1, "hidpi": false, "refresh": 60] as [AnyHashable: Any]
        }
        print("请求 host 规格 \(specs.map { "\($0.0)x\($0.1)" }.joined(separator: ", "))（\(specs.count) 屏）")
    }
    // 解码回调在每屏的帧队列上；present 本身线程安全，这里只做 displayID → 视图查表。
    client.onPixelBuffer = { displayID, pb, _, capturedAtUs in
        router.view(for: displayID)?.present(pb, capturedAtUs: capturedAtUs)
    }
    func wireSlot(_ slot: DisplaySlot) {
        slot.view.onInputEvent = { event in
            do {
                try client.session?.sendInputEvent(event)
                slot.inputSent += 1
            } catch { slot.inputFailed += 1 }
        }
        slot.view.onCloseRequest = {
            closedByUser = true
            NSApp.stop(nil)
        }
        slot.view.onToggleImmersive = { applyImmersive(!immersive) }
    }

    print("连接 \(connectHost):\(port)")
    do {
        try client.startAsClient(to: connectHost, port: port, timeout: handshakeMs)
    } catch {
        print("✗ 握手失败: \(error.localizedDescription)")
        return 3
    }
    print("握手完成 \(client.handshakeMs) ms")
    guard client.wait(forStreamingTimeoutMs: waitMs) else {
        print("✗ 未进入 STREAMING: \(client.error?.localizedDescription ?? "unknown")")
        return 4
    }
    print("已 STREAMING，接收 \(durationMs) ms")

    let remote = client.session?.remoteDisplays ?? []
    bindSlots(remote, allowShrink: false)
    if remote.count < slots.count {
        print("⚠ host 只提供 \(remote.count) 块屏，其余 \(slots.count - remote.count) 个窗口不接收画面")
    }

    // FR-07：换屏结果回到主线程重绑窗口；失败保持原窗口（Host 会保持旧屏）。
    var updateResults: [[String: Any]] = []
    client.onSessionUpdateResult = { updateID, ok, displays, detail in
        DispatchQueue.main.async {
            if ok {
                router.reset()
                bindSlots(displays, allowShrink: true)
                print("换屏 #\(updateID) 成功：\(displays.count) 屏")
            } else {
                print("⚠ 换屏 #\(updateID) 被拒：\(detail ?? "unknown")（保持原屏）")
            }
            updateResults.append(["updateID": updateID, "ok": ok,
                                  "displays": displays.count, "detail": detail ?? ""])
        }
    }
    for at in updateAtMs {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(at)) {
            guard !updateSpecs.isEmpty else {
                print("⚠ --update-at 未给 --update-spec，跳过")
                return
            }
            let dicts = updateSpecs.map {
                ["w": $0.0, "h": $0.1, "hidpi": false, "refresh": 60] as [AnyHashable: Any]
            }
            var updateErr: NSError?
            let updateID = client.requestSessionUpdate(withSpecs: dicts, error: &updateErr)
            if updateID > 0 {
                print("换屏请求 #\(updateID) → "
                      + updateSpecs.map { "\($0.0)x\($0.1)" }.joined(separator: ", "))
            } else {
                print("✗ 换屏请求失败: \(updateErr?.localizedDescription ?? "unknown")")
            }
        }
    }

    for (at, text) in sendTexts {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(at)) {
            let displayID = slots.first?.displayID ?? 0
            let event: [AnyHashable: Any] = [
                "kind": "text",
                "displayID": displayID,
                "flags": ["cmd": false, "shift": false, "opt": false,
                          "ctrl": false, "caps": false],
                "text": text,
            ]
            do {
                try client.session?.sendInputEvent(event)
                print("文本上行 \(text.count) 字 → displayID=\(displayID)")
            } catch {
                print("✗ 文本上行失败: \(error.localizedDescription)")
            }
        }
    }

    let stopItem = DispatchWorkItem {
        if !closedByUser { NSApp.stop(nil) }
        if let wake = NSEvent.otherEvent(with: .applicationDefined,
                                         location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil,
                                         subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(wake, atStart: false)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(durationMs), execute: stopItem)
    DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        slots.first?.window.makeKeyAndOrderFront(nil)
        if CommandLine.arguments.contains("--immersive") { applyImmersive(true) }
    }
    app.run()

    client.flushFrames()
    client.flushSaves()

    var totalCompleted: UInt64 = 0, totalDecoded: UInt64 = 0, totalDropped: UInt64 = 0
    var totalRendered: UInt = 0, totalRenderDropped: UInt = 0, totalOccluded: UInt = 0
    var maxP50 = 0.0, maxP95 = 0.0
    var perDisplay: [[String: Any]] = []
    for idNum in client.receiverDisplayIDs {
        let displayID = idNum.uint32Value
        guard let rx = client.receiver(forDisplayID: displayID) else { continue }
        let st = rx.stats
        let slot = slots.first { $0.displayID == displayID }
        totalCompleted += st.framesCompleted
        totalDecoded += st.framesDecoded
        totalDropped += st.framesDropped
        let rendered = slot?.view.framesRendered ?? 0
        let renderDropped = slot?.view.framesDropped ?? 0
        let occluded = slot?.view.framesSkippedOccluded ?? 0
        totalRendered += rendered
        totalRenderDropped += renderDropped
        totalOccluded += occluded
        let p50 = slot?.view.presentLatencyP50Ms ?? 0
        let p95 = slot?.view.presentLatencyP95Ms ?? 0
        maxP50 = max(maxP50, p50)
        maxP95 = max(maxP95, p95)
        perDisplay.append([
            "displayID": displayID,
            "width": rx.videoWidth, "height": rx.videoHeight,
            "framesCompleted": st.framesCompleted,
            "framesDecoded": st.framesDecoded,
            "framesDropped": st.framesDropped,
            "framesRendered": rendered,
            "presentP50Ms": p50, "presentP95Ms": p95,
        ])
        print("client[\(displayID)]: 收齐=\(st.framesCompleted) 解码=\(st.framesDecoded) "
              + "丢帧=\(st.framesDropped) 尺寸=\(rx.videoWidth)x\(rx.videoHeight) "
              + "上屏=\(rendered) p95=\(String(format: "%.1f", p95))ms")
    }
    let inputSent = slots.reduce(0) { $0 + $1.inputSent }
    let inputFailed = slots.reduce(0) { $0 + $1.inputFailed }
    print("client: 重组完成=\(totalCompleted) 解码=\(totalDecoded) 丢帧=\(totalDropped) "
          + "渲染=\(totalRendered) 渲染丢帧=\(totalRenderDropped)")
    print("client: 上屏 p50=\(maxP50) ms p95=\(maxP95) ms "
          + "时钟 offset=\(client.session?.clockOffsetUs ?? 0) us（样本 \(client.session?.timeSyncSamples ?? 0)）")
    print("client: 输入上行 \(inputSent)/失败 \(inputFailed) | 控制最大间隔=\(client.maxControlGapMs) ms "
          + "PNG=\(client.savedFrames)")
    if !updateResults.isEmpty {
        let okCount = updateResults.filter { ($0["ok"] as? Bool) == true }.count
        print("client: 换屏请求 \(updateResults.count) 次，成功 \(okCount) 次")
    }
    if let outPath = outPath, let data = try? JSONSerialization.data(withJSONObject: [
        "framesCompleted": totalCompleted,
        "framesDecoded": totalDecoded,
        "framesDropped": totalDropped,
        "framesRendered": totalRendered,
        "framesRenderDropped": totalRenderDropped,
        "framesSkippedOccluded": totalOccluded,
        "presentP50Ms": maxP50,
        "presentP95Ms": maxP95,
        "decodedWidth": client.decodedWidth,
        "decodedHeight": client.decodedHeight,
        "clockOffsetUs": client.session?.clockOffsetUs ?? 0,
        "timeSyncSamples": client.session?.timeSyncSamples ?? 0,
        "inputSent": inputSent, "inputFailed": inputFailed,
        "maxControlGapMs": client.maxControlGapMs,
        "savedPNG": client.savedFrames,
        "sessionUpdates": updateResults,
        "displays": perDisplay,
    ], options: .prettyPrinted) {
        try? data.write(to: URL(fileURLWithPath: outPath))
    }
    client.shutdown()
    return 0
}

if CommandLine.arguments.contains("--selftest") {
    exit(runSelftest() ? 0 : 1)
}
if CommandLine.arguments.contains("--connect") {
    exit(runConnect())
}

banner("VeilRD client — Swift 主 + ObjC 桥（D-02）")
demoPairing()
demoTakeover()
demoSession()
demoInputAndIsolation()
demoRenderPipeline()
banner("桥接验证完成：Swift ↔ ObjC 双向可用")
