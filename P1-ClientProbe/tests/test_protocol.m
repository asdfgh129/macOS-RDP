// ProtocolCodec 单元测试：纯内存，不建屏、不联网、不碰 WindowServer。
// 覆盖 PROTOCOL.md §3（控制消息）、§4（帧头/分片/丢帧判据）。
#import <Foundation/Foundation.h>
#import "ProtocolCodec.h"

static int gFail = 0;

static void Expect(BOOL cond, const char *name) {
    if (cond) {
        printf("[PASS] %s\n", name);
    } else {
        gFail++;
        printf("[FAIL] %s\n", name);
    }
}

static void ExpectInt(long got, long want, const char *name) {
    if (got == want) {
        printf("[PASS] %s\n", name);
    } else {
        gFail++;
        printf("[FAIL] %s got=%ld want=%ld\n", name, got, want);
    }
}

static P1FrameHeader MakeHeader(uint32_t display, uint32_t seq, uint8_t idx, uint8_t count, uint8_t flags) {
    P1FrameHeader h = {0};
    h.flags = flags;
    h.displayID = display;
    h.frameSeq = seq;
    h.fragIdx = idx;
    h.fragCount = count;
    h.payloadLen = 0;  // 由调用方填
    return h;
}

int main(void) {
    @autoreleasepool {
        // ---------------- 控制通道 ----------------
        NSError *err = nil;
        NSDictionary *hb = P1MakeControlMessage(@"heartbeat", 42, @{@"ts": @(1794887000.5)});
        NSData *frame = P1EncodeControlMessage(hb, &err);
        Expect(frame.length > 4 && err == nil, "control-encode-ok");

        // 长度前缀：大端，且等于 JSON 字节数
        const uint8_t *p = frame.bytes;
        uint32_t prefix = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
                          ((uint32_t)p[2] << 8) | p[3];
        ExpectInt(prefix, (long)frame.length - 4, "control-length-prefix");

        // 整帧解析
        NSData *body = [frame subdataWithRange:NSMakeRange(4, frame.length - 4)];
        NSDictionary *decoded = P1DecodeControlMessage(body, &err);
        Expect([decoded[@"type"] isEqual:@"heartbeat"], "control-decode-type");
        ExpectInt([decoded[@"seq"] integerValue], 42, "control-decode-seq");
        Expect([decoded[@"v"] integerValue] == 1, "control-decode-version");

        // 流式：两条消息粘在一个 buffer 里
        NSData *f2 = P1EncodeControlMessage(P1MakeControlMessage(@"bye", 43, @{@"reason": @"done"}), &err);
        P1ControlFrameParser *parser = [[P1ControlFrameParser alloc] init];
        [parser appendData:frame];
        [parser appendData:f2];
        NSDictionary *m1 = [parser nextMessageWithError:&err];
        NSDictionary *m2 = [parser nextMessageWithError:&err];
        NSDictionary *m3 = [parser nextMessageWithError:&err];
        Expect([m1[@"type"] isEqual:@"heartbeat"], "parser-first-of-two");
        Expect([m2[@"type"] isEqual:@"bye"], "parser-second-of-two");
        Expect(m3 == nil && err == nil, "parser-empty-tail-no-error");
        ExpectInt((long)parser.bufferedBytes, 0, "parser-buffer-drained");

        // 流式：逐字节喂（最极端的拆包）
        P1ControlFrameParser *byteParser = [[P1ControlFrameParser alloc] init];
        NSUInteger got = 0;
        for (NSUInteger i = 0; i < frame.length; i++) {
            [byteParser appendData:[frame subdataWithRange:NSMakeRange(i, 1)]];
            if ([byteParser nextMessageWithError:&err]) got++;
        }
        ExpectInt((long)got, 1, "parser-byte-by-byte");

        // 半个长度前缀：不报错、不产出
        P1ControlFrameParser *stub = [[P1ControlFrameParser alloc] init];
        [stub appendData:[frame subdataWithRange:NSMakeRange(0, 3)]];
        err = nil;
        Expect([stub nextMessageWithError:&err] == nil && err == nil, "parser-partial-prefix");

        // 长度前缀为 0：必须报错并清空（流错位，不能继续攒）
        P1ControlFrameParser *bad = [[P1ControlFrameParser alloc] init];
        uint8_t zero[8] = {0};
        [bad appendData:[NSData dataWithBytes:zero length:8]];
        err = nil;
        Expect([bad nextMessageWithError:&err] == nil &&
               [err.domain isEqual:P1ProtocolErrorDomain] &&
               err.code == P1ProtocolErrorBadLength, "parser-zero-length-errors");
        ExpectInt((long)bad.bufferedBytes, 0, "parser-zero-length-clears");

        // 缺 seq 不得编码
        err = nil;
        Expect(P1EncodeControlMessage(@{@"type": @"hello"}, &err) == nil &&
               err.code == P1ProtocolErrorBadMessage, "control-reject-missing-seq");

        // 版本错
        err = nil;
        Expect(P1EncodeControlMessage(@{@"v": @2, @"type": @"hello", @"seq": @1}, &err) == nil &&
               err.code == P1ProtocolErrorBadVersion, "control-reject-bad-version");

        // 非 JSON 载荷
        err = nil;
        Expect(P1EncodeControlMessage(@{@"type": @"x", @"seq": @1, @"bad": [NSDate date]}, &err) == nil,
               "control-reject-non-json");

        // 解码侧：坏 JSON / 缺 type
        err = nil;
        Expect(P1DecodeControlMessage([@"not json" dataUsingEncoding:NSUTF8StringEncoding], &err) == nil &&
               err.code == P1ProtocolErrorBadJSON, "decode-bad-json");
        err = nil;
        Expect(P1DecodeControlMessage([@"{\"v\":1}" dataUsingEncoding:NSUTF8StringEncoding], &err) == nil &&
               err.code == P1ProtocolErrorBadMessage, "decode-missing-type");

        // ---------------- 帧头 ----------------
        P1FrameHeader h = MakeHeader(4128835, 100, 0, 1, P1FrameFlagKeyframe | P1FrameFlagHasParamSets);
        h.payloadLen = 900;
        NSData *packed = P1PackFrameHeader(h);
        // v2：帧头 18B（fragIdx/fragCount 各 16 位）
        ExpectInt((long)packed.length, 18, "header-size-18");

        const uint8_t *hb2 = packed.bytes;
        Expect(hb2[0] == 0x4D && hb2[1] == 0x52, "header-magic-bytes");
        ExpectInt(hb2[2], P1FrameHeaderVersion, "header-version-byte");
        ExpectInt(hb2[3], P1FrameFlagKeyframe | P1FrameFlagHasParamSets, "header-flags-byte");
        // displayID 大端：4128835 = 0x3F0043（取自 2026-11-17 真机 create 日志）
        Expect(hb2[4] == 0x00 && hb2[5] == 0x3F && hb2[6] == 0x00 && hb2[7] == 0x43,
               "header-displayid-bigendian");

        P1FrameHeader back = {0};
        Expect(P1UnpackFrameHeader(packed, &back, &err), "header-unpack-ok");
        Expect(back.displayID == h.displayID && back.frameSeq == h.frameSeq &&
               back.fragIdx == h.fragIdx && back.fragCount == h.fragCount &&
               back.payloadLen == h.payloadLen && back.flags == h.flags,
               "header-roundtrip-fields");

        // 坏 magic
        NSMutableData *badMagic = [packed mutableCopy];
        ((uint8_t *)badMagic.mutableBytes)[0] = 0x00;
        err = nil;
        Expect(!P1UnpackFrameHeader(badMagic, &back, &err) && err.code == P1ProtocolErrorBadMagic,
               "header-bad-magic");

        // fragIdx >= fragCount
        P1FrameHeader badIdx = MakeHeader(1, 1, 2, 2, 0);
        badIdx.payloadLen = 10;
        err = nil;
        Expect(!P1UnpackFrameHeader(P1PackFrameHeader(badIdx), &back, &err) &&
               err.code == P1ProtocolErrorBadHeader, "header-fragidx-out-of-range");

        // payloadLen 超上限
        P1FrameHeader big = MakeHeader(1, 1, 0, 1, 0);
        big.payloadLen = 1201;
        err = nil;
        Expect(!P1UnpackFrameHeader(P1PackFrameHeader(big), &back, &err) &&
               err.code == P1ProtocolErrorPayloadTooLarge, "header-payload-too-large");

        // 不足 16 字节
        err = nil;
        Expect(!P1UnpackFrameHeader([packed subdataWithRange:NSMakeRange(0, 10)], &back, &err) &&
               err.code == P1ProtocolErrorTruncated, "header-truncated");

        // ---------------- 分片与重组 ----------------
        // D-01：QUIC 头空间安全值 1150，留出 1200B MTU 的余量
        ExpectInt((long)P1FrameMaxPayload, 1150, "frame-max-payload-1150");
        Expect(P1FrameMaxPayload + 50 <= 1200, "datagram-headroom-ok");
        NSMutableData *payload = [NSMutableData data];
        for (int i = 0; i < 3000; i++) {
            uint8_t b = (uint8_t)(i & 0xFF);
            [payload appendBytes:&b length:1];
        }
        P1FrameHeader proto = MakeHeader(4128835, 1, 0, 0, P1FrameFlagKeyframe);
        err = nil;
        NSArray<NSData *> *frags = P1FragmentPayload(payload, proto, &err);
        ExpectInt((long)frags.count, 3, "fragment-count-ceil");
        Expect(err == nil, "fragment-no-error");

        P1FrameReassembler *ra = [[P1FrameReassembler alloc] init];
        NSData *whole = nil;
        int lastFlagCount = 0;
        for (NSData *f in frags) {
            P1FrameHeader fh = {0};
            Expect(P1UnpackFrameHeader(f, &fh, &err), "fragment-header-unpacks");
            Expect(fh.payloadLen <= P1FrameMaxPayload, "fragment-payload-within-limit");
            ExpectInt(fh.fragCount, 3, "fragment-count-field");
            if (fh.flags & P1FrameFlagLastFragment) lastFlagCount++;
            NSData *bodyData = [f subdataWithRange:NSMakeRange(P1FrameHeaderSize, f.length - P1FrameHeaderSize)];
            NSData *done = [ra acceptHeader:fh payload:bodyData error:&err];
            if (done) whole = done;
        }
        ExpectInt(lastFlagCount, 1, "fragment-only-last-flagged");
        Expect(whole != nil && [whole isEqualToData:payload], "reassemble-equals-original");
        Expect(!ra.needsKeyframe, "reassemble-no-keyframe-needed");
        ExpectInt((long)ra.droppedFrames, 0, "reassemble-no-drops");

        // 大帧往返：v1 的 255 片上限在这里会直接拒发。用 400 片（≈460KB，超过
        // 3440×1440 关键帧的典型体积）验证分片→重组逐字节一致。
        {
            NSUInteger bigLen = P1FrameMaxPayload * 400 - 137;   // 不足整片，覆盖末片短载荷
            NSMutableData *big = [NSMutableData dataWithLength:bigLen];
            uint8_t *bp = big.mutableBytes;
            for (NSUInteger i = 0; i < bigLen; i++) bp[i] = (uint8_t)(i * 31 + 7);

            P1FrameHeader bh = MakeHeader(7, 4242, 0, 1, P1FrameFlagKeyframe | P1FrameFlagHasParamSets);
            err = nil;
            NSArray<NSData *> *shards = P1FragmentPayload(big, bh, &err);
            Expect(shards.count == 400 && err == nil, "big-frame-400-shards");

            P1FrameHeader firstHC = {0};
            P1UnpackFrameHeader(shards.firstObject, &firstHC, NULL);
            P1FrameHeader lastHC = {0};
            P1UnpackFrameHeader(shards.lastObject, &lastHC, NULL);
            ExpectInt(firstHC.fragCount, 400, "big-frame-count-field");
            ExpectInt(lastHC.fragIdx, 399, "big-frame-last-index");

            P1FrameReassembler *bigRA = [[P1FrameReassembler alloc] init];
            NSData *bigWhole = nil;
            for (NSData *sh in shards) {
                P1FrameHeader fh = {0};
                if (!P1UnpackFrameHeader(sh, &fh, NULL)) continue;
                NSData *body = [sh subdataWithRange:NSMakeRange(P1FrameHeaderSize,
                                                               sh.length - P1FrameHeaderSize)];
                NSData *done = [bigRA acceptHeader:fh payload:body error:NULL];
                if (done) bigWhole = done;
            }
            Expect(bigWhole != nil && [bigWhole isEqualToData:big], "big-frame-reassemble-equals");
            ExpectInt((long)bigRA.droppedFrames, 0, "big-frame-no-drops");
        }

        // frameSeq 缺口 → 需要关键帧
        P1FrameReassembler *gap = [[P1FrameReassembler alloc] init];
        NSData *chunk = [@"AAAA" dataUsingEncoding:NSUTF8StringEncoding];
        P1FrameHeader s1 = MakeHeader(9, 1, 0, 1, P1FrameFlagKeyframe);
        s1.payloadLen = (uint16_t)chunk.length;
        Expect([gap acceptHeader:s1 payload:chunk error:&err] != nil, "gap-seq1-complete");

        P1FrameHeader s3 = MakeHeader(9, 3, 0, 1, 0);   // 缺 seq 2
        s3.payloadLen = (uint16_t)chunk.length;
        Expect([gap acceptHeader:s3 payload:chunk error:&err] != nil, "gap-seq3-still-delivers");
        Expect(gap.needsKeyframe, "gap-detects-and-wants-keyframe");
        ExpectInt((long)gap.droppedFrames, 1, "gap-drop-count");

        P1FrameHeader s4 = MakeHeader(9, 4, 0, 1, P1FrameFlagKeyframe);
        s4.payloadLen = (uint16_t)chunk.length;
        [gap acceptHeader:s4 payload:chunk error:&err];
        Expect(!gap.needsKeyframe, "gap-keyframe-clears-flag");

        // 中间分片先到（前缀分片丢失）
        P1FrameReassembler *ooo = [[P1FrameReassembler alloc] init];
        P1FrameHeader mid = MakeHeader(9, 10, 1, 3, 0);
        mid.payloadLen = (uint16_t)chunk.length;
        Expect([ooo acceptHeader:mid payload:chunk error:&err] == nil, "ooo-mid-frag-dropped");
        Expect(ooo.needsKeyframe, "ooo-wants-keyframe");

        // 两块屏交错：进入另一块屏必须丢弃并要关键帧
        P1FrameReassembler *mix = [[P1FrameReassembler alloc] init];
        P1FrameHeader a0 = MakeHeader(100, 1, 0, 2, P1FrameFlagKeyframe);
        a0.payloadLen = (uint16_t)chunk.length;
        [mix acceptHeader:a0 payload:chunk error:&err];          // 屏 A 第 0 片
        P1FrameHeader b0 = MakeHeader(200, 1, 0, 1, 0);          // 屏 B 插进来
        b0.payloadLen = (uint16_t)chunk.length;
        NSData *bDone = [mix acceptHeader:b0 payload:chunk error:&err];
        Expect(bDone != nil, "mix-b-frame-completes");
        Expect(mix.needsKeyframe, "mix-requests-keyframe");
        Expect(mix.droppedFrames >= 1, "mix-drops-a-frame");

        // payloadLen 与实参不符必须拒绝
        P1FrameHeader lie = MakeHeader(7, 1, 0, 1, 0);
        lie.payloadLen = 999;
        err = nil;
        P1FrameReassembler *lieRA = [[P1FrameReassembler alloc] init];
        Expect([lieRA acceptHeader:lie payload:chunk error:&err] == nil &&
               err.code == P1ProtocolErrorBadHeader, "reject-payloadlen-mismatch");

        // 256 片在过去（v1，fragCount 为 uint8）是要报错的，v2 起合法：
        // 3440×1440 的关键帧本来就会超过 255 片，这正是 v2 要解决的事。
        NSMutableData *over255 = [NSMutableData dataWithLength:P1FrameMaxPayload * 256];
        err = nil;
        NSArray *many = P1FragmentPayload(over255, proto, &err);
        Expect(many.count == 256 && err == nil, "fragment-256-shards-allowed");
        {
            P1FrameHeader last = {0};
            P1UnpackFrameHeader(many.lastObject, &last, NULL);
            ExpectInt(last.fragCount, 256, "fragment-256-count-field");
            ExpectInt(last.fragIdx, 255, "fragment-256-last-index");
        }

        // 分片真正过多：超过 fragCount 的 16 位上限（65535）
        NSMutableData *huge = [NSMutableData dataWithLength:P1FrameMaxPayload * 65536];
        err = nil;
        Expect(P1FragmentPayload(huge, proto, &err) == nil &&
               err.code == P1ProtocolErrorPayloadTooLarge, "fragment-too-many");

        // reset 清状态
        [gap reset];
        Expect(!gap.needsKeyframe && gap.droppedFrames == 0, "reset-clears-state");

        printf(gFail ? "\n%d FAILED\n" : "\nALL PASS\n", gFail);
    }
    return gFail ? 1 : 0;
}
