#!/usr/bin/env python3
"""把 Mach-O 里的 LC_UUID 钉成固定值，让同一份源码的两次构建字节相同。

ld64 不接受 -uuid，-Wl,-no_uuid 又会被 dyld 拒绝（missing LC_UUID），
所以只能链接后原地改写这条 load command。改完必须重新做 ad-hoc 签名，
否则签名覆盖的哈希对不上、加载会被拒。
"""
import sys, struct, subprocess

FIXED = bytes.fromhex("8a5d0000000000000000beefdeadc0de")
LC_UUID, LC_CODE_SIGNATURE = 0x1B, 0x1D

def main(path):
    with open(path, "r+b") as f:
        data = bytearray(f.read())
        magic = struct.unpack_from("<I", data, 0)[0]
        if magic != 0xFEEDFACF:
            print("skip: 不是 64 位小端 Mach-O", file=sys.stderr)
            return 0
        ncmds = struct.unpack_from("<I", data, 16)[0]
        off = 32
        patched = 0
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", data, off)
            if cmd == LC_UUID:
                data[off + 8: off + 24] = FIXED
                patched += 1
            elif cmd == LC_CODE_SIGNATURE:
                # 签名段在文件尾部，先截掉，改完再签
                sig_off = struct.unpack_from("<I", data, off + 8)[0]
                data = data[:sig_off]
            off += size
        with open(path, "wb") as f:
            f.write(data)
        if patched != 1:
            print(f"warn: 期望 1 条 LC_UUID，实际 {patched}", file=sys.stderr)
    subprocess.run(["codesign", "--force", "-s", "-", path],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
