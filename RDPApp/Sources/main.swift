//
//  main.swift
//  RDPApp
//
//  D-02「Swift 主 + ObjC 桥」的可编译骨架验证：
//    - Swift 侧实现 ObjC protocol（M1SessionDriver）并注入给 ObjC 协调器
//    - Swift 侧调用 ObjC 纯逻辑（配对 TOFU / 接管手势 / 输入计划 / 隔离判定）
//  本版不含 Metal 渲染与帧管线（D-10 参数待 P2 微调），聚焦桥接可用性与
//  Host 会话编排的 Swift 驱动骨架。真实 WindowServer 驱动（M1RDPDriver）由
//  RDPKit 提供，在 build.sh 中一起编译验证。
//

import Foundation

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

banner("RDPApp — Swift 主 + ObjC 桥骨架（D-02）")
demoPairing()
demoTakeover()
demoSession()
demoInputAndIsolation()
banner("桥接验证完成：Swift ↔ ObjC 双向可用")
