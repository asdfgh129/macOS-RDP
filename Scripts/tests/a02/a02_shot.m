//
//  a02_shot.m
//  A-02 玻璃到玻璃（无相机替代法）：客户端侧「截屏 + 条码判读」
//
//  一次调用 = 一次采样：
//    1) 记录 t0（CLOCK_REALTIME 微秒）
//    2) CGDisplayCreateImage 抓当前帧缓冲（就是屏幕上“已经可见”的那一帧）
//    3) 记录 t1
//    4) 在这张图上解出主机侧条码里的 epoch 毫秒
//  采样延迟 = (t0+t1)/2 − clockMs（同机时无需时钟差；跨机再减 host−client 时钟差）。
//
//  为什么用条码而不是 OCR：解码是确定性的，不受字体/视频压缩的字符误识影响；
//  8 位校验 + 行极性校验会直接丢弃坏样本，不会把误读当测量值。
//
//  用法：
//    ./a02_shot --display 1 [--png out.png] [--max-skew-sec 3600]
//    ./a02_shot --list
//  输出：一行 JSON（stdout）。
//  退出码：0 成功；2 抓图失败；3 找不到条码；4 几何不自洽；5 校验失败。
//
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <time.h>

static uint64_t A02NowUs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)(ts.tv_nsec / 1000);
}

static uint64_t A02NowMs(void) { return A02NowUs() / 1000ull; }

typedef struct {
    uint8_t *px;      // RGBA8
    size_t w, h, stride;
} A02Bitmap;

static BOOL A02BitmapFromImage(CGImageRef img, A02Bitmap *out) {
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    if (w == 0 || h == 0) return NO;
    uint8_t *buf = calloc(w * h * 4, 1);
    if (!buf) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NO; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), img);
    CGContextRelease(ctx);
    out->px = buf; out->w = w; out->h = h; out->stride = w * 4;
    return YES;
}

static inline int A02Lum(const uint8_t *p) {
    return (p[0] * 299 + p[1] * 587 + p[2] * 114) / 1000;
}

// 在 [cx-r, cx+r] × [cy-r, cy+r] 取平均亮度（越界自动裁剪）。
static double A02MeanLum(const A02Bitmap *bm, double cx, double cy, double r) {
    long x0 = (long)floor(cx - r), x1 = (long)ceil(cx + r);
    long y0 = (long)floor(cy - r), y1 = (long)ceil(cy + r);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= (long)bm->w) x1 = (long)bm->w - 1;
    if (y1 >= (long)bm->h) y1 = (long)bm->h - 1;
    if (x1 < x0 || y1 < y0) return -1;
    double sum = 0; long n = 0;
    for (long y = y0; y <= y1; y++) {
        const uint8_t *row = bm->px + (size_t)y * bm->stride;
        for (long x = x0; x <= x1; x++) { sum += A02Lum(row + x * 4); n++; }
    }
    return n ? sum / (double)n : -1;
}

typedef struct {
    int ok;
    const char *why;
    uint64_t clockMs;
    double cell;
    long bx, by, bw, bh;
    double whiteRowMean, blackRowMean;
    uint8_t bytes[7];
} A02Decode;

typedef enum { A02FrameMagenta = 0, A02FrameCyan = 1 } A02FrameColor;

typedef struct {
    const A02Bitmap *bm;
    uint8_t *mask;
    long hits;
} A02MaskScan;

// 同色像素可能有多份（屏幕上直出的一份、流里白的一份、再加一层镜中镜的鬼影），
// 先做连通域，再按「面积 + 形状（57:4 条码框）」挑出真正的那一个。
static BOOL A02ColorHit(const uint8_t *p, A02FrameColor fc) {
    if (fc == A02FrameMagenta) return (p[0] >= 140 && p[1] <= 115 && p[2] >= 140);
    return (p[0] <= 115 && p[1] >= 140 && p[2] >= 140);
}

typedef struct { long bx, by, bw, bh, area; } A02Comp;

// 返回面积最大的连通域；--rect 已由调用方裁剪，这里只处理整幅图。
static BOOL A02LargestComponent(const A02Bitmap *bm, A02FrameColor fc, A02Comp *out) {
    size_t n = bm->w * bm->h;
    uint8_t *mask = calloc(n, 1);
    if (!mask) return NO;
    long hits = 0;
    for (size_t y = 0; y < bm->h; y++) {
        const uint8_t *row = bm->px + y * bm->stride;
        for (size_t x = 0; x < bm->w; x++) {
            if (A02ColorHit(row + x * 4, fc)) { mask[y * bm->w + x] = 1; hits++; }
        }
    }
    if (hits < 200) { free(mask); return NO; }

    int32_t *stack = malloc(sizeof(int32_t) * 65536);
    size_t cap = 65536;
    BOOL found = NO;
    A02Comp best = {0};
    for (size_t y = 0; y < bm->h && best.area < (long)n; y++) {
        for (size_t x = 0; x < bm->w; x++) {
            size_t idx = y * bm->w + x;
            if (!mask[idx] || mask[idx] == 2) continue;
            // BFS
            size_t sp = 0;
            stack[sp++] = (int32_t)idx;
            mask[idx] = 2;
            long area = 0, minX = (long)x, maxX = (long)x, minY = (long)y, maxY = (long)y;
            while (sp) {
                int32_t cur = stack[--sp];
                size_t cy = (size_t)cur / bm->w, cx = (size_t)cur % bm->w;
                area++;
                if ((long)cx < minX) minX = (long)cx;
                if ((long)cx > maxX) maxX = (long)cx;
                if ((long)cy < minY) minY = (long)cy;
                if ((long)cy > maxY) maxY = (long)cy;
                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        if (!dx && !dy) continue;
                        long nx = (long)cx + dx, ny = (long)cy + dy;
                        if (nx < 0 || ny < 0 || nx >= (long)bm->w || ny >= (long)bm->h) continue;
                        size_t ni = (size_t)ny * bm->w + (size_t)nx;
                        if (mask[ni] != 1) continue;
                        mask[ni] = 2;
                        if (sp == cap) { cap *= 2; stack = realloc(stack, sizeof(int32_t) * cap); }
                        stack[sp++] = (int32_t)ni;
                    }
                }
            }
            if (area > best.area) {
                best.area = area;
                best.bx = minX; best.by = minY;
                best.bw = maxX - minX + 1; best.bh = maxY - minY + 1;
                found = YES;
            }
        }
    }
    free(stack);
    free(mask);
    if (!found) return NO;
    *out = best;
    return YES;
}

static A02Decode A02DecodeBarcode(const A02Bitmap *bm, A02FrameColor fc) {
    A02Decode r = {0};
    r.why = "unknown";

    A02Comp comp = {0};
    if (!A02LargestComponent(bm, fc, &comp)) { r.why = "no-color-frame"; return r; }
    r.bx = comp.bx; r.by = comp.by; r.bw = comp.bw; r.bh = comp.bh;

    // 外框是空心的，命中率约 20–30%；零散同色像素拼出来的大框会被密度拦掉。
    double density = (double)comp.area / ((double)comp.bw * (double)comp.bh);
    if (density < 0.08) { r.why = "sparse-color"; return r; }
    if (comp.bw < 57 * 2 || comp.bh < 4 * 2) { r.why = "pattern-too-small"; return r; }

    // 水平与垂直缩放不一定相同（采集缩放 3440→1280、上屏再缩放一次），
    // 必须分别用 Cx/Cy 定位：用平均值会在 56 格上累积到半格，直接把位读错。
    double Cx = (double)r.bw / 57.0;      // 56 格 + 两侧各 C/2
    double Cy = (double)r.bh / 4.0;       // 3 行 + 两侧各 C/2
    double c = (Cx + Cy) / 2.0;
    r.cell = c;
    if (fabs(Cx - Cy) > 0.35 * c) { r.why = "aspect-mismatch"; return r; }

    // 行极性：数据行上方应显著亮于下方（行 0 白 / 行 2 黑）
    double dataY = (double)r.by + 2.0 * Cy;
    r.whiteRowMean = A02MeanLum(bm, (double)r.bx + (double)r.bw / 2.0,
                                (double)r.by + 1.0 * Cy, Cy * 0.4);
    r.blackRowMean = A02MeanLum(bm, (double)r.bx + (double)r.bw / 2.0,
                                (double)r.by + 3.0 * Cy, Cy * 0.4);
    if (r.whiteRowMean < 0 || r.blackRowMean < 0) { r.why = "row-sample-failed"; return r; }
    if (r.whiteRowMean <= r.blackRowMean + 25) { r.why = "polarity"; return r; }

    // 逐格判读（取格心 35% 见方，抗压缩振铃）
    BOOL bits[56];
    double sr = fmax(1.0, fmin(Cx, Cy) * 0.175);
    for (int i = 0; i < 56; i++) {
        double cx = (double)r.bx + Cx / 2.0 + ((double)i + 0.5) * Cx;
        double lum = A02MeanLum(bm, cx, dataY, sr);
        if (lum < 0) { r.why = "cell-sample-failed"; return r; }
        bits[i] = lum > 128.0;
    }
    for (int b = 0; b < 7; b++) {
        uint8_t v = 0;
        for (int j = 0; j < 8; j++) v = (uint8_t)((v << 1) | (bits[b * 8 + j] ? 1 : 0));
        r.bytes[b] = v;
    }
    uint8_t xr = 0;
    for (int i = 0; i < 6; i++) xr ^= r.bytes[i];
    if (r.bytes[6] != (uint8_t)((xr ^ 0xA5) & 0xFF)) { r.why = "checksum"; return r; }

    uint64_t ms = 0;
    for (int i = 0; i < 6; i++) ms = (ms << 8) | r.bytes[i];
    r.clockMs = ms;
    r.ok = 1;
    r.why = "ok";
    return r;
}

// 把整幅图裁剪成 rect（用于只看客户端窗口内容，避开屏幕上直出的那份条码）。
static BOOL A02CropBitmap(const A02Bitmap *src, long x, long y, long w, long h, A02Bitmap *dst) {
    if (x < 0 || y < 0 || w <= 0 || h <= 0) return NO;
    if (x + w > (long)src->w || y + h > (long)src->h) return NO;
    uint8_t *buf = calloc((size_t)w * (size_t)h * 4, 1);
    if (!buf) return NO;
    for (long row = 0; row < h; row++) {
        memcpy(buf + (size_t)row * (size_t)w * 4,
               src->px + (size_t)(y + row) * src->stride + (size_t)x * 4, (size_t)w * 4);
    }
    dst->px = buf; dst->w = (size_t)w; dst->h = (size_t)h; dst->stride = (size_t)w * 4;
    return YES;
}

static void A02WritePNG(CGImageRef img, NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
                                                                CFSTR("public.png"), 1, NULL);
    if (!dst) return;
    CGImageDestinationAddImage(dst, img, NULL);
    CGImageDestinationFinalize(dst);
    CFRelease(dst);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        uint32_t displayID = CGMainDisplayID();
        NSString *pngPath = nil;
        double maxSkewSec = 3600;
        double rx = 0, ry = 0, rw = 0, rh = 0;
        BOOL hasRect = NO;
        BOOL two = NO;
        NSString *pngIn = nil;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--two")) {
                two = YES;
            } else if (!strcmp(argv[i], "--display") && i + 1 < argc) {
                displayID = (uint32_t)strtoul(argv[++i], NULL, 10);
            } else if (!strcmp(argv[i], "--rect") && i + 1 < argc) {
                // 只抓条码所在的小区域：整屏抓图单次 300–600ms，会把测量变成「买表看时间」，
                // 小区域抓图能把窗口压到毫秒级。
                NSString *s = [NSString stringWithUTF8String:argv[++i]];
                NSArray *p = [s componentsSeparatedByString:@","];
                if (p.count == 4) {
                    rx = [p[0] doubleValue]; ry = [p[1] doubleValue];
                    rw = [p[2] doubleValue]; rh = [p[3] doubleValue];
                    hasRect = (rw >= 32 && rh >= 16);
                }
            } else if (!strcmp(argv[i], "--png-in") && i + 1 < argc) {
                pngIn = [NSString stringWithUTF8String:argv[++i]];
            } else if (!strcmp(argv[i], "--png") && i + 1 < argc) {
                pngPath = [NSString stringWithUTF8String:argv[++i]];
            } else if (!strcmp(argv[i], "--max-skew-sec") && i + 1 < argc) {
                maxSkewSec = atof(argv[++i]);
            } else if (!strcmp(argv[i], "--list-windows")) {
                CFArrayRef arr = CGWindowListCopyWindowInfo(
                    kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                    kCGNullWindowID);
                for (CFIndex k = 0; k < CFArrayGetCount(arr); k++) {
                    NSDictionary *w = (__bridge NSDictionary *)CFArrayGetValueAtIndex(arr, k);
                    CGRect b = CGRectZero;
                    CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &b);
                    NSLog(@"win %-4d layer=%-4d %-20s %4.0fx%-4.0f+%4.0f+%-4.0f %@",
                          [w[(id)kCGWindowNumber] intValue],
                          [w[(id)kCGWindowLayer] intValue],
                          [w[(id)kCGWindowOwnerName] UTF8String] ?: "?",
                          b.size.width, b.size.height, b.origin.x, b.origin.y,
                          w[(id)kCGWindowName] ?: @"");
                }
                CFRelease(arr);
                return 0;
            } else if (!strcmp(argv[i], "--list")) {
                uint32_t ids[16]; uint32_t n = 0;
                if (CGGetActiveDisplayList(16, ids, &n) == kCGErrorSuccess) {
                    for (uint32_t k = 0; k < n; k++) {
                        CGRect r = CGDisplayBounds(ids[k]);
                        printf("display id=%u bounds=%.0fx%.0f+%.0f+%.0f main=%d vendor=0x%x\n",
                               ids[k], r.size.width, r.size.height, r.origin.x, r.origin.y,
                               (int)(ids[k] == CGMainDisplayID()),
                               (unsigned)CGDisplayVendorNumber(ids[k]));
                    }
                }
                return 0;
            } else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
                printf("用法: a02_shot [--display ID] [--png PATH] [--max-skew-sec N] [--list]\n");
                return 0;
            }
        }

        if (pngIn) {
            NSURL *u = [NSURL fileURLWithPath:pngIn];
            CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)u, NULL);
            if (!src) { printf("{\"ok\":false,\"why\":\"png-open-failed\"}\n"); return 2; }
            CGImageRef im = CGImageSourceCreateImageAtIndex(src, 0, NULL);
            CFRelease(src);
            if (!im) { printf("{\"ok\":false,\"why\":\"png-decode-failed\"}\n"); return 2; }
            A02Bitmap full = {0};
            if (!A02BitmapFromImage(im, &full)) { CGImageRelease(im); return 2; }
            A02Bitmap b2 = {0};
            if (hasRect) {
                if (!A02CropBitmap(&full, (long)rx, (long)ry, (long)rw, (long)rh, &b2)) {
                    printf("{\"ok\":false,\"why\":\"crop-out-of-range\"}\n");
                    free(full.px); CGImageRelease(im); return 2;
                }
                free(full.px);
            } else { b2 = full; }
            A02Decode hd = A02DecodeBarcode(&b2, A02FrameMagenta);
            A02Decode rd = A02DecodeBarcode(&b2, A02FrameCyan);
            printf("{\"ok\":%s,\"hostWhy\":\"%s\",\"localWhy\":\"%s\",\"hostMs\":%llu,"
                   "\"localMs\":%llu,\"latencyMs\":%lld,\"hostCell\":%.2f,\"localCell\":%.2f,"
                   "\"hostBBox\":[%ld,%ld,%ld,%ld],\"localBBox\":[%ld,%ld,%ld,%ld],"
                   "\"hostBytes\":[%u,%u,%u,%u,%u,%u,%u],"
                   "\"whiteRow\":%.1f,\"blackRow\":%.1f,\"width\":%zu,\"height\":%zu}\n",
                   (hd.ok && rd.ok) ? "true" : "false", hd.why, rd.why,
                   hd.clockMs, rd.clockMs,
                   (long long)rd.clockMs - (long long)hd.clockMs,
                   hd.cell, rd.cell, hd.bx, hd.by, hd.bw, hd.bh,
                   rd.bx, rd.by, rd.bw, rd.bh,
                   hd.bytes[0], hd.bytes[1], hd.bytes[2], hd.bytes[3],
                   hd.bytes[4], hd.bytes[5], hd.bytes[6],
                   hd.whiteRowMean, hd.blackRowMean, b2.w, b2.h);
            free(b2.px); CGImageRelease(im);
            return (hd.ok && rd.ok) ? 0 : 3;
        }

        uint64_t t0 = A02NowUs();
        CGImageRef img = hasRect
            ? CGDisplayCreateImageForRect((CGDirectDisplayID)displayID,
                                          CGRectMake(rx, ry, rw, rh))
            : CGDisplayCreateImage((CGDirectDisplayID)displayID);
        uint64_t t1 = A02NowUs();
        if (!img) {
            printf("{\"ok\":false,\"why\":\"capture-failed\",\"t0Us\":%llu,\"t1Us\":%llu}\n",
                   t0, t1);
            return 2;
        }
        if (pngPath) A02WritePNG(img, pngPath);

        A02Bitmap bm = {0};
        int rc = 0;
        A02Decode d = {0};
        A02Decode ref = {0};
        A02Bitmap full = {0};
        if (!A02BitmapFromImage(img, &full)) {
            d.why = "bitmap-failed";
            rc = 2;
        } else {
            if (hasRect) {
                if (!A02CropBitmap(&full, (long)rx, (long)ry, (long)rw, (long)rh, &bm)) {
                    printf("{\"ok\":false,\"why\":\"crop-out-of-range\"}\n");
                    free(full.px); CGImageRelease(img); return 2;
                }
                free(full.px);
            } else { bm = full; }
            d = A02DecodeBarcode(&bm, A02FrameMagenta);
            if (two) ref = A02DecodeBarcode(&bm, A02FrameCyan);
            if (!d.ok) rc = (strcmp(d.why, "checksum") == 0) ? 5
                          : (strcmp(d.why, "aspect-mismatch") == 0 ? 4 : 3);
        }

        uint64_t nowMs = A02NowMs();
        long long skew = d.ok ? (long long)nowMs - (long long)d.clockMs : 0;
        if (d.ok && (double)llabs(skew) > maxSkewSec * 1000.0) {
            d.ok = 0; d.why = "skew"; rc = 6;
        }

        if (two) {
            // 双钟模式：同一张截帧里同时读出「主机被采集的时间」与「本机渲染的时间」，
            // 差值即端到端延迟，截屏本身的耗时与时刻完全不参与计算。
            long long latency = (d.ok && ref.ok) ? (long long)ref.clockMs - (long long)d.clockMs : 0;
            printf("{\"ok\":%s,\"why\":\"%s\",\"hostMs\":%llu,\"localMs\":%llu,"
                   "\"latencyMs\":%lld,\"hostWhy\":\"%s\",\"localWhy\":\"%s\","
                   "\"hostCell\":%.2f,\"localCell\":%.2f,\"t0Us\":%llu,\"t1Us\":%llu,"
                   "\"captureMs\":%.1f,\"display\":%u,\"width\":%zu,\"height\":%zu}\n",
                   (d.ok && ref.ok) ? "true" : "false",
                   (d.ok && ref.ok) ? "ok" : (d.ok ? ref.why : d.why),
                   d.clockMs, ref.clockMs, latency,
                   d.why, ref.why, d.cell, ref.cell, t0, t1,
                   (double)(t1 - t0) / 1000.0, displayID, bm.w, bm.h);
            if (!(d.ok && ref.ok)) rc = 3;
        } else {
            printf("{\"ok\":%s,\"why\":\"%s\",\"clockMs\":%llu,\"t0Us\":%llu,\"t1Us\":%llu,"
                   "\"cellPx\":%.2f,\"bbox\":[%ld,%ld,%ld,%ld],\"whiteRow\":%.1f,\"blackRow\":%.1f,"
                   "\"skewMs\":%lld,\"display\":%u,\"width\":%zu,\"height\":%zu}\n",
                   d.ok ? "true" : "false", d.why, d.clockMs, t0, t1,
                   d.cell, d.bx, d.by, d.bw, d.bh, d.whiteRowMean, d.blackRowMean,
                   skew, displayID, bm.w, bm.h);
        }
        if (bm.px) free(bm.px);
        CGImageRelease(img);
        return rc;
    }
}
