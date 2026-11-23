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

func runConnect() -> Int32 {
    let args = CommandLine.arguments
    func arg(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
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
    let win = parseSize(arg("--window") ?? "1280x720") ?? (1280, 720)
    let saveFrames = Int(arg("--save-frames") ?? "5") ?? 5
    let outdir = arg("--outdir") ?? ""
    let outPath = arg("--out")
    let spec = parseSize(arg("--spec") ?? "0x0")

    M1FrameReceiver.prewarmDecoder()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let content = NSRect(x: 0, y: 0, width: win.0, height: win.1)
    let window = NSWindow(contentRect: content,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.title = "VeilRD \(win.0)×\(win.1)（Esc 退出）"
    window.isReleasedWhenClosed = false
    window.acceptsMouseMovedEvents = true
    let frameView = M1FrameView(frame: content)
    window.contentView = frameView
    window.center()
    window.makeKeyAndOrderFront(nil)

    var closedByUser = false
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                           object: window, queue: .main) { _ in
        closedByUser = true
        NSApp.stop(nil)
    }

    let client = M1StreamClientNode()
    client.expectedFingerprint = fingerprint
    client.outdir = outdir
    client.saveFrames = UInt(saveFrames)
    if let spec = spec {
        client.requestedSpecs = [["w": spec.0, "h": spec.1, "hidpi": false, "refresh": 60]]
        print("请求 host 规格 \(spec.0)x\(spec.1)")
    }
    client.prepareReceiver()
    client.onPixelBuffer = { pb, _, capturedAtUs in
        frameView.present(pb, capturedAtUs: capturedAtUs)
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

    if let display = client.session?.remoteDisplays.first,
       let displayID = display["displayID"] as? NSNumber {
        frameView.displayID = displayID.uint32Value
        print("目标屏 displayID=\(frameView.displayID)")
    }
    var inputSent = 0, inputFailed = 0
    frameView.onInputEvent = { event in
        do {
            try client.session?.sendInputEvent(event)
            inputSent += 1
        } catch { inputFailed += 1 }
    }
    frameView.onCloseRequest = {
        closedByUser = true
        NSApp.stop(nil)
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
        window.makeKeyAndOrderFront(nil)
    }
    app.run()

    client.flushFrames()
    client.flushSaves()
    let st = client.receiver?.stats
    print("client: 重组完成=\(st?.framesCompleted ?? 0) 解码=\(st?.framesDecoded ?? 0) "
          + "丢帧=\(st?.framesDropped ?? 0) 渲染=\(frameView.framesRendered) "
          + "渲染丢帧=\(frameView.framesDropped)")
    print("client: 上屏 p50=\(frameView.presentLatencyP50Ms) ms p95=\(frameView.presentLatencyP95Ms) ms "
          + "时钟 offset=\(client.session?.clockOffsetUs ?? 0) us（样本 \(client.session?.timeSyncSamples ?? 0)）")
    print("client: 输入上行 \(inputSent)/失败 \(inputFailed) | 控制最大间隔=\(client.maxControlGapMs) ms "
          + "PNG=\(client.savedFrames)")
    if let outPath = outPath, let data = try? JSONSerialization.data(withJSONObject: [
        "framesCompleted": st?.framesCompleted ?? 0,
        "framesDecoded": st?.framesDecoded ?? 0,
        "framesDropped": st?.framesDropped ?? 0,
        "framesRendered": frameView.framesRendered,
        "presentP50Ms": frameView.presentLatencyP50Ms,
        "presentP95Ms": frameView.presentLatencyP95Ms,
        "clockOffsetUs": client.session?.clockOffsetUs ?? 0,
        "timeSyncSamples": client.session?.timeSyncSamples ?? 0,
        "inputSent": inputSent, "inputFailed": inputFailed,
        "maxControlGapMs": client.maxControlGapMs,
        "savedPNG": client.savedFrames,
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
