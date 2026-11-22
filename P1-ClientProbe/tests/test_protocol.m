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
        h.capturedAtUs = 1763835600123456ULL;   // 2025-11-22T12:20:00.123456Z 附近的 epoch us
        NSData *packed = P1PackFrameHeader(h);
        // v3：帧头 26B（新增 64-bit 采集墙钟）
        ExpectInt((long)packed.length, 26, "header-size-26");

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
               back.payloadLen == h.payloadLen && back.flags == h.flags &&
               back.capturedAtUs == h.capturedAtUs,
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
        NSMutableData *whole = [NSMutableData data];
        int lastFlagCount = 0;
        for (NSData *f in frags) {
            P1FrameHeader fh = {0};
            Expect(P1UnpackFrameHeader(f, &fh, &err), "fragment-header-unpacks");
            Expect(fh.payloadLen <= P1FrameMaxPayload, "fragment-payload-within-limit");
            ExpectInt(fh.fragCount, 3, "fragment-count-field");
            if (fh.flags & P1FrameFlagLastFragment) lastFlagCount++;
            NSData *bodyData = [f subdataWithRange:NSMakeRange(P1FrameHeaderSize, f.length - P1FrameHeaderSize)];
            NSArray<P1ReassembledFrame *> *done = [ra acceptHeader:fh payload:bodyData error:&err];
            for (P1ReassembledFrame *fr in done) [whole appendData:fr.payload];
        }
        ExpectInt(lastFlagCount, 1, "fragment-only-last-flagged");
        Expect(whole.length > 0 && [whole isEqualToData:payload], "reassemble-equals-original");
        Expect(!ra.needsKeyframe, "reassemble-no-keyframe-needed");
        ExpectInt((long)ra.droppedFrames, 0, "reassemble-no-drops");

        // 同一帧的分片倒序到达：v3 起必须能收齐，不再整帧作废。
        {
            P1FrameReassembler *ooo = [[P1FrameReassembler alloc] init];
            NSMutableData *all = [NSMutableData data];
            for (NSData *f in [frags reverseObjectEnumerator]) {
                P1FrameHeader fh = {0};
                P1UnpackFrameHeader(f, &fh, NULL);
                NSData *bodyData = [f subdataWithRange:NSMakeRange(P1FrameHeaderSize,
                                                                   f.length - P1FrameHeaderSize)];
                for (P1ReassembledFrame *fr in [ooo acceptHeader:fh payload:bodyData error:NULL]) {
                    [all appendData:fr.payload];
                }
            }
            Expect([all isEqualToData:payload], "ooo-within-frame-reassembles");
            Expect(!ooo.needsKeyframe, "ooo-within-frame-no-keyframe");
        }

        // 大帧往返：v1 的 255 片上限在这里会直接拒发。用 400 片（≈460KB，超过
        // 255 片的旧上限），验证 v2 的 16 位分片号端到端可用。
        {
            NSMutableData *big = [NSMutableData dataWithLength:400 * P1FrameMaxPayload];
            NSError *bigErr = nil;
            NSArray<NSData *> *bigFrags = P1FragmentPayload(big, proto, &bigErr);
            Expect(bigFrags != nil && bigErr == nil, "big-frame-fragment-ok");
            P1FrameReassembler *bigRA = [[P1FrameReassembler alloc] init];
            NSMutableData *bigWhole = [NSMutableData data];
            for (NSData *f in bigFrags) {
                P1FrameHeader fh = {0};
                if (!P1UnpackFrameHeader(f, &fh, NULL)) continue;
                NSData *body = [f subdataWithRange:NSMakeRange(P1FrameHeaderSize,
                                                               f.length - P1FrameHeaderSize)];
                for (P1ReassembledFrame *fr in [bigRA acceptHeader:fh payload:body error:NULL]) {
                    [bigWhole appendData:fr.payload];
                }
            }
            Expect([bigWhole isEqualToData:big], "big-frame-reassemble-equals");
            ExpectInt((long)bigRA.droppedFrames, 0, "big-frame-no-drops");
        }

        // 跨帧乱序：seq0(key) → seq2 → seq1，必须按 0,1,2 顺序交付。
        {
            P1FrameReassembler *ro = [[P1FrameReassembler alloc] init];
            NSData *f0 = [@"frame-0-" dataUsingEncoding:NSUTF8StringEncoding];
            NSData *f1 = [@"frame-1-" dataUsingEncoding:NSUTF8StringEncoding];
            NSData *f2 = [@"frame-2-" dataUsingEncoding:NSUTF8StringEncoding];
            P1FrameHeader h0 = MakeHeader(9, 0, 0, 1, P1FrameFlagKeyframe);
            P1FrameHeader h1 = MakeHeader(9, 1, 0, 1, 0);
            P1FrameHeader h2 = MakeHeader(9, 2, 0, 1, 0);
            h0.payloadLen = (uint16_t)f0.length;
            h1.payloadLen = (uint16_t)f1.length;
            h2.payloadLen = (uint16_t)f2.length;
            h0.capturedAtUs = 1763835600111000ULL;
            h1.capturedAtUs = 1763835600112000ULL;
            h2.capturedAtUs = 1763835600113000ULL;
            NSArray *d0 = [ro acceptHeader:h0 payload:f0 nowMs:1000 error:NULL];
            NSArray *d2 = [ro acceptHeader:h2 payload:f2 nowMs:1010 error:NULL];
            Expect(d0.count == 1, "reorder-seq0-delivered");
            Expect(d0.count == 1 && d0[0].capturedAtUs == h0.capturedAtUs,
                   "reorder-seq0-capture-ts");
            Expect(d2.count == 0, "reorder-seq2-held");
            Expect(!ro.needsKeyframe, "reorder-not-lost-before-deadline");
            NSArray<P1ReassembledFrame *> *d1 = [ro acceptHeader:h1 payload:f1 nowMs:1020 error:NULL];
            Expect(d1.count == 2, "reorder-release-two-in-order");
            if (d1.count == 2) {
                Expect(d1[0].frameSeq == 1 && [d1[0].payload isEqualToData:f1], "reorder-seq1-first");
                Expect(d1[1].frameSeq == 2 && [d1[1].payload isEqualToData:f2], "reorder-seq2-second");
                Expect(d1[0].capturedAtUs == h1.capturedAtUs &&
                       d1[1].capturedAtUs == h2.capturedAtUs,
                       "reorder-release-capture-ts");
            }
            ExpectInt((long)ro.droppedFrames, 0, "reorder-no-drops");
        }

        // 真丢帧：seq1 一直不来，超过帧期限（120ms）后才判丢并要关键帧。
        {
            P1FrameReassembler *gap = [[P1FrameReassembler alloc] init];
            NSData *chunk = [@"AAAA" dataUsingEncoding:NSUTF8StringEncoding];
            P1FrameHeader s0 = MakeHeader(9, 0, 0, 1, P1FrameFlagKeyframe);
            P1FrameHeader s2 = MakeHeader(9, 2, 0, 1, 0);
            P1FrameHeader s3 = MakeHeader(9, 3, 0, 1, 0);
            s0.payloadLen = s2.payloadLen = s3.payloadLen = (uint16_t)chunk.length;
            Expect([gap acceptHeader:s0 payload:chunk nowMs:1000 error:&err].count == 1,
                   "gap-seq0-keyframe-delivered");
            Expect([gap acceptHeader:s2 payload:chunk nowMs:1010 error:&err].count == 0,
                   "gap-seq2-held-not-delivered");
            Expect(!gap.needsKeyframe, "gap-within-deadline-no-keyframe");
            Expect([gap acceptHeader:s3 payload:chunk nowMs:1200 error:&err].count == 0,
                   "gap-after-deadline-nothing-delivered");
            Expect(gap.needsKeyframe, "gap-after-deadline-wants-keyframe");
            Expect(gap.droppedFrames >= 3, "gap-counts-lost-and-dependent-frames");

            P1FrameHeader s5k = MakeHeader(9, 5, 0, 1, P1FrameFlagKeyframe);
            s5k.payloadLen = (uint16_t)chunk.length;
            NSArray<P1ReassembledFrame *> *kf =
                [gap acceptHeader:s5k payload:chunk nowMs:1210 error:&err];
            Expect(kf.count == 1 && kf[0].keyframe, "gap-keyframe-delivered-after-loss");
            Expect(!gap.needsKeyframe, "gap-keyframe-clears-flag");
        }

        // 缺口期间的非关键帧一律丢弃，不能喂给解码器。
        {
            P1FrameReassembler *pf = [[P1FrameReassembler alloc] init];
            NSData *chunk = [@"BBBB" dataUsingEncoding:NSUTF8StringEncoding];
            P1FrameHeader p = MakeHeader(9, 1, 0, 1, 0);
            p.payloadLen = (uint16_t)chunk.length;
            Expect([pf acceptHeader:p payload:chunk error:&err].count == 0,
                   "p-frame-before-keyframe-discarded");
            Expect(pf.needsKeyframe, "first-frame-must-be-keyframe");
        }

        // 首帧从中间分片开始（前缀分片丢了）：v3 起允许等待其余分片，但非关键帧仍不交付。
        {
            P1FrameReassembler *mid = [[P1FrameReassembler alloc] init];
            NSData *chunk = [@"CCCC" dataUsingEncoding:NSUTF8StringEncoding];
            P1FrameHeader m1 = MakeHeader(9, 0, 1, 3, P1FrameFlagKeyframe);
            m1.payloadLen = (uint16_t)chunk.length;
            Expect([mid acceptHeader:m1 payload:chunk error:&err].count == 0,
                   "mid-frag-held");
            Expect(mid.needsKeyframe, "mid-frag-still-needs-keyframe");
        }

        // 同一帧重复分片只计一次。
        {
            P1FrameReassembler *dup = [[P1FrameReassembler alloc] init];
            NSData *chunk = [@"DDDD" dataUsingEncoding:NSUTF8StringEncoding];
            P1FrameHeader h0 = MakeHeader(9, 0, 0, 2, P1FrameFlagKeyframe);
            P1FrameHeader h1 = MakeHeader(9, 0, 1, 2, P1FrameFlagKeyframe);
            h0.payloadLen = h1.payloadLen = (uint16_t)chunk.length;
            [dup acceptHeader:h0 payload:chunk error:NULL];
            [dup acceptHeader:h0 payload:chunk error:NULL];
            NSArray<P1ReassembledFrame *> *done = [dup acceptHeader:h1 payload:chunk error:NULL];
            Expect(done.count == 1, "duplicate-fragment-delivers-once");
            Expect(dup.fragmentsDiscarded >= 1, "duplicate-fragment-counted");
        }

        // 单屏会话：别的 displayID 的分片忽略，不打断本屏。
        {
            P1FrameReassembler *mix = [[P1FrameReassembler alloc] init];
            NSData *chunk = [@"EEEE" dataUsingEncoding:NSUTF8StringEncoding];
            P1FrameHeader a0 = MakeHeader(100, 1, 0, 2, P1FrameFlagKeyframe);
            P1FrameHeader a1 = MakeHeader(100, 1, 1, 2, P1FrameFlagKeyframe);
            P1FrameHeader b0 = MakeHeader(200, 7, 0, 1, P1FrameFlagKeyframe);
            a0.payloadLen = a1.payloadLen = b0.payloadLen = (uint16_t)chunk.length;
            Expect([mix acceptHeader:a0 payload:chunk error:&err].count == 0, "mix-a0-held");
            Expect([mix acceptHeader:b0 payload:chunk error:&err].count == 0, "mix-other-display-ignored");
            NSArray<P1ReassembledFrame *> *aDone = [mix acceptHeader:a1 payload:chunk error:&err];
            Expect(aDone.count == 1 && aDone[0].displayID == 100, "mix-a-frame-completes");
            Expect(!mix.needsKeyframe, "mix-no-keyframe-needed");
            Expect(mix.fragmentsDiscarded >= 1, "mix-ignored-fragment-counted");
        }

        // payloadLen 与实参不符必须拒绝
        NSData *chunk = [@"ZZZZ" dataUsingEncoding:NSUTF8StringEncoding];
        P1FrameHeader lie = MakeHeader(7, 1, 0, 1, 0);
        lie.payloadLen = 999;
        err = nil;
        P1FrameReassembler *lieRA = [[P1FrameReassembler alloc] init];
        Expect([lieRA acceptHeader:lie payload:chunk error:&err].count == 0 &&
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

        // reset 清状态：统计归零，并重新要求首关键帧
        P1FrameReassembler *resetRA = [[P1FrameReassembler alloc] init];
        NSData *rc = [@"RRRR" dataUsingEncoding:NSUTF8StringEncoding];
        P1FrameHeader rh = MakeHeader(9, 0, 0, 1, P1FrameFlagKeyframe);
        rh.payloadLen = (uint16_t)rc.length;
        [resetRA acceptHeader:rh payload:rc error:NULL];
        [resetRA reset];
        Expect(resetRA.needsKeyframe && resetRA.droppedFrames == 0 &&
               resetRA.fragmentsDiscarded == 0, "reset-clears-state");

        printf(gFail ? "\n%d FAILED\n" : "\nALL PASS\n", gFail);
    }
    return gFail ? 1 : 0;
}
