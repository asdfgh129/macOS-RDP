//
//  patha_probe.m
//  独占态 Path A（锁屏 / 登录窗）取证工具
//
//  只做三件事，全部走公开 API + 一个私有符号：
//    state   打印 CGSessionCopyCurrentDictionary 里的锁屏/在台/用户字段
//    lock    调用 SACLockScreenImmediate（login.framework，dlsym）
//    capture 用 CGDisplayCreateImage 把主屏落成 PNG（屏幕录制授权由调用方继承）
//
//  为什么需要它：§5.32 的独占态 lock 试验混合了两个变量——调用上下文（SSH 进程
//  不在 Aqua session）与独占态本身。本工具必须由 GUI Terminal 启动，才能把
//  「Aqua 上下文」固定住，只留「物理屏全禁」这一个变量。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <ImageIO/ImageIO.h>
#import <libproc.h>

typedef int (*SACLockScreenImmediateFn)(void);

static void PostUnicode(pid_t pid, UniChar u, CGKeyCode code, BOOL down) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, code, down);
    if (!e) return;
    if (u != 0) CGEventKeyboardSetUnicodeString(e, 1, &u);
    CGEventPostToPid(pid, e);
    CFRelease(e);
}

static pid_t FindLoginwindow(void) {
    int cap = proc_listallpids(NULL, 0);
    if (cap <= 0) return 0;
    pid_t *pids = calloc((size_t)cap, sizeof(pid_t));
    if (!pids) return 0;
    int n = proc_listallpids(pids, cap * (int)sizeof(pid_t));
    pid_t found = 0;
    for (int i = 0; i < n; i++) {
        char name[2 * MAXPATHLEN] = {0};
        if (proc_name(pids[i], name, sizeof(name)) > 0 && strcmp(name, "loginwindow") == 0) {
            found = pids[i];
            break;
        }
    }
    free(pids);
    return found;
}

static void PrintState(const char *tag) {
    NSDictionary *d = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    printf("[%s] session=%s\n", tag,
           d ? [[d description] UTF8String] : "(nil)");
    printf("[%s] screenIsLocked=%s onConsole=%s loginDone=%s userName=%s\n", tag,
           [[d[@"CGSSessionScreenIsLocked"] description] UTF8String] ?: "nil",
           [[d[@"kCGSSessionOnConsoleKey"] description] UTF8String] ?: "nil",
           [[d[@"kCGSessionLoginDoneKey"] description] UTF8String] ?: "nil",
           [[d[@"kCGSSessionUserNameKey"] description] UTF8String] ?: "nil");
    fflush(stdout);
}

static BOOL LockNow(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
                     RTLD_LAZY);
    if (!h) h = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY);
    if (!h) { printf("lock: dlopen 失败 %s\n", dlerror()); return NO; }
    SACLockScreenImmediateFn fn = (SACLockScreenImmediateFn)dlsym(h, "SACLockScreenImmediate");
    if (!fn) { printf("lock: 符号缺失\n"); return NO; }
    int rc = fn();
    printf("lock: SACLockScreenImmediate rc=%d\n", rc);
    fflush(stdout);
    return rc == 0;
}

static BOOL CaptureTo(const char *path) {
    CGImageRef img = CGDisplayCreateImage(CGMainDisplayID());
    if (!img) { printf("capture: CGDisplayCreateImage 返回 NULL（缺屏幕录制授权？）\n"); return NO; }
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
                                                               CFSTR("public.png"), 1, NULL);
    if (!dst) { CGImageRelease(img); printf("capture: 建 PNG destination 失败\n"); return NO; }
    CGImageDestinationAddImage(dst, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    printf("capture: %s %s (%zux%zu)\n", ok ? "OK" : "FAIL", path,
           CGImageGetWidth(img), CGImageGetHeight(img));
    CGImageRelease(img);
    fflush(stdout);
    return ok;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *cmd = (argc > 1) ? [NSString stringWithUTF8String:argv[1]] : @"state";
        if ([cmd isEqualToString:@"state"]) {
            PrintState("state");
            return 0;
        }
        if ([cmd isEqualToString:@"lock"]) {
            BOOL ok = LockNow();
            sleep(3);
            PrintState("after-lock");
            return ok ? 0 : 1;
        }
        if ([cmd isEqualToString:@"capture"]) {
            const char *p = (argc > 2) ? argv[2] : "/tmp/patha.png";
            return CaptureTo(p) ? 0 : 1;
        }
        if ([cmd isEqualToString:@"lock-state"]) {
            // 锁屏 → 等 5s → 打状态 → 落图，一次跑完给 wrapper 用
            const char *p = (argc > 2) ? argv[2] : "/tmp/patha-after-lock.png";
            PrintState("before");
            LockNow();
            sleep(5);
            PrintState("after");
            CaptureTo(p);
            return 0;
        }
        if ([cmd isEqualToString:@"unlock"]) {
            // 从 stdin 读密码，避免出现在 argv / ps 里；日志只打长度。
            NSData *data = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
            NSString *pw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            pw = [pw stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            pid_t lw = FindLoginwindow();
            printf("unlock: loginwindow pid=%d, credential length=%lu\n",
                   lw, (unsigned long)pw.length);
            if (lw <= 0) return 1;
            for (NSUInteger i = 0; i < pw.length; i++) {
                UniChar u = [pw characterAtIndex:i];
                PostUnicode(lw, u, 0, YES);
                PostUnicode(lw, u, 0, NO);
            }
            PostUnicode(lw, 0, 36, YES);   // Return
            PostUnicode(lw, 0, 36, NO);
            sleep(2);
            PrintState("after-unlock");
            return 0;
        }
        printf("用法: patha_probe state|lock|capture [png]|lock-state [png]|unlock < password\n");
        return 2;
    }
}
