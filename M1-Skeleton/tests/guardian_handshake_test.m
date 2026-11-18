//
//  guardian_handshake_test.m
//  M1-Skeleton
//
//  负向安全测试：宿主二进制「没有实现 --guardian」时，P0VStartGuardian 必须返回 NO。
//
//  为什么需要这条测试：
//    2026-11-18 事故中，pipeline_kiosk_probe 没处理 --guardian，守护子进程打印用法后
//    立刻退出，父进程却以为「有兜底」，照常禁掉全部物理屏 —— 屏幕从此没人恢复。
//    现在 P0VStartGuardian 用 <snapshot>.guardian-ready 做就绪握手，本测试就是钉住这个
//    不变式：宁可禁屏失败，也不能在没有兜底的情况下动显示配置。
//
//  本测试不做任何显示配置变更（守护只会在父进程异常退出时才恢复，而这里父进程正常结束）。
//

#import <Foundation/Foundation.h>
#import "P0VDisplayControl.h"

int main(void) {
    @autoreleasepool {
        // 故意不处理 --guardian：模拟「忘了实现守护」的宿主进程。
        // 子进程会走到下面，打印 usage 并以 2 退出。
        if ([[[NSProcessInfo processInfo] arguments] count] > 1) {
            fprintf(stderr, "usage: guardian_handshake_test（本程序刻意不支持 --guardian）\n");
            return 2;
        }

        NSString *path = @"/tmp/m1-guardian-handshake-test.json";
        NSData *empty = [@"{\"probe\":true}" dataUsingEncoding:NSUTF8StringEncoding];
        [empty writeToFile:path atomically:YES];

        NSError *err = nil;
        BOOL started = P0VStartGuardian(path, getpid(), &err);

        printf("P0VStartGuardian -> %s\n", started ? "YES（错误）" : "NO（正确）");
        printf("error = %s\n", err.localizedDescription.UTF8String ?: "(nil)");

        if (started) {
            printf("[FAIL] 宿主未实现 --guardian，却仍然允许禁屏 —— 黑屏无兜底风险回归\n");
            return 1;
        }
        if (!err) {
            printf("[FAIL] 失败但没给出原因\n");
            return 1;
        }
        printf("[PASS] 无兜底时拒绝启动守护，禁屏链路被阻断\n");
        return 0;
    }
}
