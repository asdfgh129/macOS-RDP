//
//  ProbeUtil.h
//  P0-TahoeProbe
//

#ifndef ProbeUtil_h
#define ProbeUtil_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

void P0Log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void P0Error(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// 结果统一以单行 JSON 打到 stdout，便于直接重定向到文件做记录。
void P0Emit(NSString *stage, NSDictionary *payload);

NSString *P0JSONString(id object);
BOOL P0WriteJSON(id object, NSString *path, NSError * _Nullable * _Nullable error);
NSDictionary * _Nullable P0ReadJSON(NSString *path);

// 手写 CGRect 字符串，避免依赖 NSStringFromCGRect 在不同 SDK/framework 组合下的可见性。
NSString *P0RectString(CGRect rect);

// 环境指纹：OS 版本 / build / 架构 / 机型 / 已登录 GUI 会话判断。
NSDictionary *P0SystemInfo(void);

// 用 Quartz 列出的当前 display 全量状态（含 offline 的 stale 项）。
NSArray<NSDictionary *> *P0DisplayList(void);

// 同步等待（命令行工具没有 AppKit run loop，用 dispatch group + 轮询即可）。
void P0SleepMs(int ms);

NS_ASSUME_NONNULL_END

#endif /* ProbeUtil_h */
