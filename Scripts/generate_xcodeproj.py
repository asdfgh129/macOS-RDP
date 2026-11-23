#!/usr/bin/env python3
# Generate VeilRD.xcodeproj/project.pbxproj (2 static libs + 3 app targets).
# 工程文件由本脚本生成，勿手工编辑 pbxproj；新增模块后改这里再重跑。
# 第 4 轮：加入 Session 共享节点层与 Platform（P0V/VD/ProbeUtil）源文件。
from pathlib import Path

ROOT = Path("/Volumes/Data/Code/macOS-RDP")
OUT = ROOT / "VeilRD.xcodeproj/project.pbxproj"

P = "000000000000000000000"
def i(n): return f"{P}{n:03X}"

RDKIT = {
    "Common": ["M1PipelineTypes", "M1WallClock"],
    "Capture": ["M1CapturePipeline"],
    "Codec": ["M1VideoEncoder"],
    "Frame": ["M1FramePipeline", "M1FrameSender", "M1FrameReceiver"],
    "Transport": ["M1QuicTransport", "M1DatagramSink", "M1MessageSink", "M1ControlLink", "M1ControlChannel", "M1ControlSession"],
    "Control": ["M1Pairing", "M1Takeover", "M1SessionCoordinator"],
    "Display": ["M1RDPDriver", "M1DriverLogic", "M1ScreenLock", "M1WindowLayout", "M1FrameView"],
    "Input": ["M1InputLogic", "M1InputInjector"],
    "Session": ["M1StreamSession"],
}
PROTO = ["ProtocolCodec", "P1SessionState", "P1InputCodec", "P1Coordinate"]
# M1RDPDriver 依赖的显示配置实现（来自探针目录，不搬文件）
PLATFORM = {
    "P0VDisplayControl": "P0V-DisplayIsolation/src/P0VDisplayControl.m",
    "VDManager": "P0-TahoeProbe/src/VDManager.m",
    "ProbeUtil": "P0-TahoeProbe/src/ProbeUtil.m",
}
RDKIT_PATHS = {m: f"Packages/RDPKit/Sources/{g}/{m}.m"
               for g, mods in RDKIT.items() for m in mods}
RDKIT_PATHS.update(PLATFORM)

# deterministic ids
fid = {}
counter = [0x400]
def oid(key):
    if key not in fid:
        counter[0] += 1
        fid[key] = i(counter[0])
    return fid[key]

lines = []
def w(s=""): lines.append(s)

# file refs
ref = {}
def file_ref(key, path, ftype="sourcecode.c.objc"):
    ref[key] = oid("ref:" + key)
    w(f'\t\t{ref[key]} /* {path} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = "{path}"; sourceTree = SOURCE_ROOT; }};')

# build files
bf = {}
def build_file(key, fileRef, comment):
    bf[key] = oid("bf:" + key)
    w(f'\t\t{bf[key]} /* {comment} in Sources */ = {{isa = PBXBuildFile; fileRef = {fileRef} /* {comment} */; }};')

w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {")
w("\t};")
w("\tobjectVersion = 56;")
w("\tobjects = {")

# --- PBXBuildFile ---
for key in ("daemon-main", "agent-main", "client-main", "bridge"):
    ref[key] = oid("ref:" + key)
w("\n/* Begin PBXBuildFile section */")
w(f'\t\t{i(0x200)} /* main.m in Sources */ = {{isa = PBXBuildFile; fileRef = {ref["daemon-main"]} /* main.m */; }};')
w(f'\t\t{i(0x201)} /* agent-main.m in Sources */ = {{isa = PBXBuildFile; fileRef = {ref["agent-main"]} /* agent-main.m */; }};')
w(f'\t\t{i(0x202)} /* main.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {ref["client-main"]} /* main.swift */; }};')
for key, comment in [("agent-rdpkit", "libRDPKit.a in Frameworks"), ("agent-proto", "libProtocolCodec.a in Frameworks"),
                     ("client-rdpkit", "libRDPKit.a in Frameworks"), ("client-proto", "libProtocolCodec.a in Frameworks")]:
    prod = i(0x024) if "rdpkit" in key else i(0x025)
    bf[key] = oid("bf:" + key)
    w(f'\t\t{bf[key]} /* {comment} */ = {{isa = PBXBuildFile; fileRef = {prod} /* {comment} */; }};')

rdkit_m = []
for m, path in RDKIT_PATHS.items():
    if not (ROOT / path).exists():
        continue
    key = f"rdkit:{m}"
    rdkit_m.append(key)
    ref[key] = oid("ref:" + key)
    bf[key] = oid("bf:" + key)
    w(f'\t\t{bf[key]} /* {m}.m in Sources */ = {{isa = PBXBuildFile; fileRef = {ref[key]} /* {m}.m */; }};')
for m in PROTO:
    key = f"proto:{m}"
    ref[key] = oid("ref:" + key)
    bf[key] = oid("bf:" + key)
    w(f'\t\t{bf[key]} /* {m}.m in Sources */ = {{isa = PBXBuildFile; fileRef = {ref[key]} /* {m}.m */; }};')
w("/* End PBXBuildFile section */")

# --- PBXContainerItemProxy ---
w("\n/* Begin PBXContainerItemProxy section */")
deps = [("agent-rdpkit", i(0x014), "RDPKit"), ("agent-proto", i(0x015), "ProtocolCodec"),
        ("client-rdpkit", i(0x014), "RDPKit"), ("client-proto", i(0x015), "ProtocolCodec")]
proxy = {}
for key, target, name in deps:
    proxy[key] = oid("proxy:" + key)
    w(f'\t\t{proxy[key]} /* PBXContainerItemProxy */ = {{')
    w(f'\t\t\tisa = PBXContainerItemProxy;')
    w(f'\t\t\tcontainerPortal = {i(1)} /* Project object */;')
    w(f'\t\t\tproxyType = 1;')
    w(f'\t\t\tremoteGlobalIDString = {target};')
    w(f'\t\t\tremoteInfo = {name};')
    w(f'\t\t}};')
w("/* End PBXContainerItemProxy section */")

# --- PBXFileReference ---
w("\n/* Begin PBXFileReference section */")
file_ref("daemon-main", "Apps/HostDaemon/Sources/main.m")
file_ref("agent-main", "Apps/HostAgent/Sources/main.m")
file_ref("client-main", "Apps/Client/Sources/main.swift", "sourcecode.swift")
file_ref("bridge", "Apps/Client/Sources/RDPApp-Bridging-Header.h", "sourcecode.c.h")
for m, p in RDKIT_PATHS.items():
    if (ROOT / p).exists():
        file_ref(f"rdkit:{m}", p)
for m in PROTO:
    file_ref(f"proto:{m}", f"Packages/ProtocolCodec/Sources/{m}.m")
for n, name in [(0x020, "veild-host-daemon"), (0x021, "veild-host-agent"), (0x022, "VeilRD"),
                (0x024, "RDPKit"), (0x025, "ProtocolCodec")]:
    typ = "compiled.mach-o.executable" if n < 0x024 else "archive.ar"
    pth = f"lib{name}.a" if n >= 0x024 else name
    w(f'\t\t{i(n)} /* {name} */ = {{isa = PBXFileReference; explicitFileType = "{typ}"; includeInIndex = 0; path = "{pth}"; sourceTree = BUILT_PRODUCTS_DIR; }};')
w("/* End PBXFileReference section */")

# --- PBXFrameworksBuildPhase ---
w("\n/* Begin PBXFrameworksBuildPhase section */")
for n, key1, key2 in [(0x060, "agent-rdpkit", "agent-proto"), (0x061, "client-rdpkit", "client-proto")]:
    w(f'\t\t{i(n)} /* Frameworks */ = {{')
    w(f'\t\t\tisa = PBXFrameworksBuildPhase;')
    w(f'\t\t\tbuildActionMask = 2147483647;')
    w(f'\t\t\tfiles = (')
    w(f'\t\t\t\t{bf[key1]} /* libRDPKit.a in Frameworks */,')
    w(f'\t\t\t\t{bf[key2]} /* libProtocolCodec.a in Frameworks */,')
    w(f'\t\t\t);')
    w(f'\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    w(f'\t\t}};')
w("/* End PBXFrameworksBuildPhase section */")

# --- PBXGroup ---
w("\n/* Begin PBXGroup section */")
w(f'\t\t{i(2)} = {{')
w(f'\t\t\tisa = PBXGroup;')
w(f'\t\t\tchildren = (')
group_ids = {}
w(f'\t\t\t\t{oid("g:apps")} /* Apps */,')
w(f'\t\t\t\t{oid("g:packages")} /* Packages */,')
w(f'\t\t\t\t{oid("g:probes")} /* Probes */,')
w(f'\t\t\t\t{i(3)} /* Products */,')
w(f'\t\t\t);')
w(f'\t\t\tsourceTree = "<group>";')
w(f'\t\t}};')

def group(key, name, children, path=None):
    gid = oid("g:" + key)
    group_ids[key] = gid
    w(f'\t\t{gid} /* {name} */ = {{')
    w(f'\t\t\tisa = PBXGroup;')
    w(f'\t\t\tchildren = (')
    for c in children: w(f'\t\t\t\t{c},')
    w(f'\t\t\t);')
    if path: w(f'\t\t\tpath = "{path}";')
    else: w(f'\t\t\tname = {name};')
    w(f'\t\t\tsourceTree = "<group>";')
    w(f'\t\t}};')
    return gid

apps_children = []
for key, name, path, files in [
    ("hostdaemon", "HostDaemon", "Apps/HostDaemon", [ref["daemon-main"]]),
    ("hostagent", "HostAgent", "Apps/HostAgent", [ref["agent-main"]]),
    ("client", "Client", "Apps/Client", [ref["client-main"], ref["bridge"]]),
]:
    apps_children.append(group(key, name, files, path))
group("apps", "Apps", apps_children)

pkg_children = []
rdkit_children = []
for g, mods in RDKIT.items():
    kids = [ref[f"rdkit:{m}"] for m in mods if f"rdkit:{m}" in ref]
    rdkit_children.append(group(f"rdkit-{g}", g, kids, f"Packages/RDPKit/Sources/{g}"))
rdkit_children.append(group("rdkit-platform", "Platform",
                            [ref[f"rdkit:{m}"] for m in PLATFORM if f"rdkit:{m}" in ref]))
pkg_children.append(group("rdkit", "RDPKit", rdkit_children, "Packages/RDPKit"))
proto_kids = [ref[f"proto:{m}"] for m in PROTO]
pkg_children.append(group("proto", "ProtocolCodec", proto_kids, "Packages/ProtocolCodec"))
group("packages", "Packages", pkg_children)
group("probes", "Probes", [], "P0V-RootDaemon")
group("products", "Products", [i(0x020), i(0x021), i(0x022), i(0x024), i(0x025)])
w("/* End PBXGroup section */")

# --- PBXNativeTarget ---
w("\n/* Begin PBXNativeTarget section */")
def native(n, name, phases, deps, conn):
    w(f'\t\t{i(n)} /* {name} */ = {{')
    w(f'\t\t\tisa = PBXNativeTarget;')
    w(f'\t\t\tbuildConfigurationList = {i(conn[0])} /* Build configuration list for PBXNativeTarget "{name}" */;')
    w(f'\t\t\tbuildPhases = (')
    for p in phases: w(f'\t\t\t\t{p},')
    w(f'\t\t\t);')
    w(f'\t\t\tbuildRules = (')
    w(f'\t\t\t);')
    w(f'\t\t\tdependencies = (')
    for d in deps: w(f'\t\t\t\t{d},')
    w(f'\t\t\t);')
    w(f'\t\t\tname = {name};')
    w(f'\t\t\tproductName = {name};')
    w(f'\t\t\tproductReference = {i({"veild-host-daemon":0x020,"veild-host-agent":0x021,"VeilRD":0x022,"RDPKit":0x024,"ProtocolCodec":0x025}[name])} /* {name} */;')
    ptype = "com.apple.product-type.library.static" if name in ("RDPKit", "ProtocolCodec") else "com.apple.product-type.tool"
    w(f'\t\t\tproductType = "{ptype}";')
    w(f'\t\t}};')
native(0x010, "veild-host-daemon", [i(0x030)], [], (0x041,))
native(0x011, "veild-host-agent", [i(0x031), i(0x060)], [oid("dep:"+k) for k,_,_ in deps[:2]], (0x042,))
native(0x012, "VeilRD", [i(0x032), i(0x061)], [oid("dep:"+k) for k,_,_ in deps[2:]], (0x043,))
native(0x014, "RDPKit", [i(0x034)], [], (0x044,))
native(0x015, "ProtocolCodec", [i(0x035)], [], (0x045,))
w("/* End PBXNativeTarget section */")

# --- PBXProject ---
w("\n/* Begin PBXProject section */")
w(f'\t\t{i(1)} /* Project object */ = {{')
w(f'\t\t\tisa = PBXProject;')
w(f'\t\t\tattributes = {{')
w(f'\t\t\t\tBuildIndependentTargetsInParallel = 1;')
w(f'\t\t\t\tLastUpgradeCheck = 2650;')
w(f'\t\t\t\tTargetAttributes = {{')
for n in (0x010,0x011,0x012,0x014,0x015):
    w(f'\t\t\t\t\t{i(n)} = {{')
    w(f'\t\t\t\t\t\tCreatedOnToolsVersion = 26.5;')
    w(f'\t\t\t\t\t}};')
w(f'\t\t\t\t}};')
w(f'\t\t\t}};')
w(f'\t\t\tbuildConfigurationList = {i(0x040)} /* Build configuration list for PBXProject "VeilRD" */;')
w(f'\t\t\tcompatibilityVersion = "Xcode 14.0";')
w(f'\t\t\tdevelopmentRegion = en;')
w(f'\t\t\thasScannedForEncodings = 0;')
w(f'\t\t\tknownRegions = (')
w(f'\t\t\t\ten,')
w(f'\t\t\t\tBase,')
w(f'\t\t\t);')
w(f'\t\t\tmainGroup = {i(2)};')
w(f'\t\t\tproductRefGroup = {i(3)} /* Products */;')
w(f'\t\t\tprojectDirPath = "";')
w(f'\t\t\tprojectRoot = "";')
w(f'\t\t\ttargets = (')
for n in (0x010,0x011,0x012,0x014,0x015): w(f'\t\t\t\t{i(n)},')
w(f'\t\t\t);')
w(f'\t\t}};')
w("/* End PBXProject section */")

# --- PBXSourcesBuildPhase ---
w("\n/* Begin PBXSourcesBuildPhase section */")
for n, files in [
    (0x030, [i(0x200)]),
    (0x031, [i(0x201)]),
    (0x032, [i(0x202)]),
    (0x034, [bf[key] for key in rdkit_m]),
    (0x035, [bf[f"proto:{m}"] for m in PROTO]),
]:
    w(f'\t\t{i(n)} /* Sources */ = {{')
    w(f'\t\t\tisa = PBXSourcesBuildPhase;')
    w(f'\t\t\tbuildActionMask = 2147483647;')
    w(f'\t\t\tfiles = (')
    for f in files: w(f'\t\t\t\t{f},')
    w(f'\t\t\t);')
    w(f'\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    w(f'\t\t}};')
w("/* End PBXSourcesBuildPhase section */")

# --- PBXTargetDependency ---
w("\n/* Begin PBXTargetDependency section */")
for key,_,_ in deps:
    oid("dep:"+key)
    w(f'\t\t{oid("dep:"+key)} /* PBXTargetDependency */ = {{')
    w(f'\t\t\tisa = PBXTargetDependency;')
    w(f'\t\t\ttarget = {i(0x014) if "rdpkit" in key else i(0x015)} /* {"RDPKit" if "rdpkit" in key else "ProtocolCodec"} */;')
    w(f'\t\t\ttargetProxy = {proxy[key]} /* PBXContainerItemProxy */;')
    w(f'\t\t}};')
w("/* End PBXTargetDependency section */")

# --- XCBuildConfiguration ---
w("\n/* Begin XCBuildConfiguration section */")
def cfg(n, name, settings, project=False):
    w(f'\t\t{i(n)} /* {name} */ = {{')
    w(f'\t\t\tisa = XCBuildConfiguration;')
    w(f'\t\t\tbuildSettings = {{')
    for k, v in settings.items():
        if isinstance(v, list):
            w(f'\t\t\t\t{k} = (')
            for item in v: w(f'\t\t\t\t\t"{item}",')
            w(f'\t\t\t\t);')
        else:
            w(f'\t\t\t\t{k} = {v};')
    w(f'\t\t\t}};')
    w(f'\t\t\tname = {name};')
    w(f'\t\t}};')

proj_common = {"ALWAYS_SEARCH_USER_PATHS":"NO", "CLANG_ENABLE_MODULES":"YES", "CLANG_ENABLE_OBJC_ARC":"YES",
               "CODE_SIGNING_ALLOWED":"NO", "GCC_WARN_UNUSED_PARAMETER":"NO",
               "MACOSX_DEPLOYMENT_TARGET":"13.0", "SDKROOT":"macosx"}
for n, name, extra in [(0x050,"Debug",{"ONLY_ACTIVE_ARCH":"YES","ENABLE_TESTABILITY":"YES"}), (0x051,"Release",{})]:
    s = dict(proj_common); s.update(extra)
    cfg(n, name, s)

HEADERS = [
    "$(SRCROOT)/Packages/RDPKit/Sources/Common", "$(SRCROOT)/Packages/RDPKit/Sources/Capture",
    "$(SRCROOT)/Packages/RDPKit/Sources/Codec", "$(SRCROOT)/Packages/RDPKit/Sources/Frame",
    "$(SRCROOT)/Packages/RDPKit/Sources/Transport", "$(SRCROOT)/Packages/RDPKit/Sources/Control",
    "$(SRCROOT)/Packages/RDPKit/Sources/Display", "$(SRCROOT)/Packages/RDPKit/Sources/Input",
    "$(SRCROOT)/Packages/RDPKit/Sources/Session",
    "$(SRCROOT)/Packages/ProtocolCodec/Sources", "$(SRCROOT)/M1-Skeleton/src",
    "$(SRCROOT)/P1-ClientProbe/src", "$(SRCROOT)/P0-TahoeProbe/src",
    "$(SRCROOT)/P0V-DisplayIsolation/src", "$(SRCROOT)/P0V-RootDaemon/src",
    "$(SRCROOT)/RDPApp/Sources", "$(SRCROOT)/Apps/Client/Sources",
]
def flags(*names):
    out = []
    for name in names:
        out += ["-framework", name]
    return out
daemon_fw = flags("Foundation","ApplicationServices","CoreGraphics","CoreVideo","ScreenCaptureKit","IOKit")
agent_fw = flags("Foundation","ApplicationServices","CoreGraphics","CoreVideo","CoreMedia","ScreenCaptureKit",
                 "VideoToolbox","Network","Security","QuartzCore","CoreImage","ImageIO","IOKit","IOSurface","AppKit")
client_fw = flags("Foundation","ApplicationServices","Cocoa","CoreGraphics","CoreVideo","CoreMedia",
                  "ScreenCaptureKit","VideoToolbox","Network","Security","QuartzCore","CoreImage","ImageIO","IOKit","IOSurface")
def app_cfg(name, frameworks, swift=False):
    s = {"HEADER_SEARCH_PATHS":HEADERS, "OTHER_LDFLAGS":frameworks, "PRODUCT_NAME":'"$(TARGET_NAME)"', "SKIP_INSTALL":"YES"}
    if swift:
        s["SWIFT_OBJC_BRIDGING_HEADER"] = '"$(SRCROOT)/Apps/Client/Sources/RDPApp-Bridging-Header.h"'
        s["SWIFT_VERSION"] = "5.0"
    return s
lib_cfg = {"HEADER_SEARCH_PATHS":HEADERS, "PRODUCT_NAME":'"$(TARGET_NAME)"', "SKIP_INSTALL":"YES",
           "CLANG_ENABLE_MODULES":"YES", "CLANG_ENABLE_OBJC_ARC":"YES",
           "MACOSX_DEPLOYMENT_TARGET":"13.0", "SDKROOT":"macosx"}
for n, name, settings in [
    (0x052,"Debug",app_cfg("daemon", daemon_fw)), (0x053,"Release",app_cfg("daemon", daemon_fw)),
    (0x054,"Debug",app_cfg("agent", agent_fw)), (0x055,"Release",app_cfg("agent", agent_fw)),
    (0x056,"Debug",app_cfg("client", client_fw, True)), (0x057,"Release",app_cfg("client", client_fw, True)),
    (0x058,"Debug",lib_cfg), (0x059,"Release",lib_cfg),
    (0x05A,"Debug",lib_cfg), (0x05B,"Release",lib_cfg),
]:
    cfg(n, name, settings)
w("/* End XCBuildConfiguration section */")

# --- XCConfigurationList ---
w("\n/* Begin XCConfigurationList section */")
for n, cfgs, label in [
    (0x040, [0x050,0x051], 'PBXProject "VeilRD"'),
    (0x041, [0x052,0x053], 'PBXNativeTarget "veild-host-daemon"'),
    (0x042, [0x054,0x055], 'PBXNativeTarget "veild-host-agent"'),
    (0x043, [0x056,0x057], 'PBXNativeTarget "VeilRD"'),
    (0x044, [0x058,0x059], 'PBXNativeTarget "RDPKit"'),
    (0x045, [0x05A,0x05B], 'PBXNativeTarget "ProtocolCodec"'),
]:
    w(f'\t\t{i(n)} /* Build configuration list for {label} */ = {{')
    w(f'\t\t\tisa = XCConfigurationList;')
    w(f'\t\t\tbuildConfigurations = (')
    for c in cfgs: w(f'\t\t\t\t{i(c)},')
    w(f'\t\t\t);')
    w(f'\t\t\tdefaultConfigurationIsVisible = 0;')
    w(f'\t\t\tdefaultConfigurationName = Release;')
    w(f'\t\t}};')
w("/* End XCConfigurationList section */")

w("\t};")
w(f"\trootObject = {i(1)} /* Project object */;")
w("}")

OUT.write_text("\n".join(lines) + "\n")
print(f"wrote {OUT} with {len(lines)} lines, rdkit_m={len(rdkit_m)}, proto={len(PROTO)}")
