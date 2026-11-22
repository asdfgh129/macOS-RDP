//
//  M1WindowLayout.h
//  M1-Skeleton
//
//  禁物理屏时 WindowServer 会把原窗口搬到剩余屏，恢复后不会回原位（DECISIONS D-05）。
//  这里提供：禁屏前的窗口布局快照 + 恢复物理屏后的搬回计划与执行。
//
//  采集（CGWindowList）与搬窗（AX）走 provider 注入；
//  快照序列化、恢复计划、目标位置夹取是纯逻辑，可离线单测。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Foundation-only 构建（单测）没有 NSValue 的 CGRect 分类，统一走字节装箱。
NS_INLINE NSValue *M1RectValue(CGRect r) {
    return [NSValue valueWithBytes:&r objCType:@encode(CGRect)];
}

NS_INLINE CGRect M1RectGetValue(NSValue *v) {
    CGRect r = CGRectZero;
    if (v) [v getValue:&r size:sizeof(r)];
    return r;
}

extern NSString * const M1WindowLayoutErrorDomain;

typedef NS_ENUM(NSInteger, M1WindowLayoutErrorCode) {
    M1WindowLayoutErrorNotTrusted = 1,
    M1WindowLayoutErrorWindowNotFound,
    M1WindowLayoutErrorMoveFailed,
};

@interface M1WindowInfo : NSObject

@property (nonatomic, assign) pid_t ownerPID;
@property (nonatomic, assign) uint32_t windowNumber;
@property (nonatomic, copy) NSString *ownerName;
@property (nonatomic, copy) NSString *title;
// 全局坐标、左上原点，与 CGWindow 的坐标一致。
@property (nonatomic, assign) CGRect frame;
// 快照时窗口中心所在屏；0 = 不在任何 active 屏。
@property (nonatomic, assign) uint32_t displayID;
@property (nonatomic, assign) NSInteger layer;

+ (instancetype)infoWithOwnerPID:(pid_t)pid
                    windowNumber:(uint32_t)windowNumber
                       ownerName:(nullable NSString *)ownerName
                           title:(nullable NSString *)title
                           frame:(CGRect)frame
                       displayID:(uint32_t)displayID
                           layer:(NSInteger)layer;

- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)infoWithDictionary:(NSDictionary *)dict;

@end

@interface M1WindowLayoutSnapshot : NSObject

@property (nonatomic, copy) NSArray<M1WindowInfo *> *windows;
// displayID -> CGRect（全局坐标）。
@property (nonatomic, copy) NSDictionary<NSNumber *, NSValue *> *displayBounds;
@property (nonatomic, assign) uint32_t mainDisplayID;

- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)snapshotWithDictionary:(NSDictionary *)dict;

@end

@interface M1WindowRestoreTask : NSObject

@property (nonatomic, strong, readonly) M1WindowInfo *window;
@property (nonatomic, assign, readonly) CGRect currentFrame;
@property (nonatomic, assign, readonly) CGRect targetFrame;

+ (instancetype)taskWithWindow:(M1WindowInfo *)window
                  currentFrame:(CGRect)currentFrame
                   targetFrame:(CGRect)targetFrame;

@end

// 纯逻辑：挑出「快照时在被禁物理屏上、现在位置变了、窗口仍存在」的窗口，
// 并把目标位置夹取到当前显示空间内（至少保留一小块可见）。
@interface M1WindowLayoutPlanner : NSObject

+ (NSArray<M1WindowRestoreTask *> *)planFromSnapshot:(M1WindowLayoutSnapshot *)snapshot
                                             windows:(NSArray<M1WindowInfo *> *)currentWindows
                                  disabledDisplayIDs:(NSSet<NSNumber *> *)disabledDisplayIDs
                                       currentBounds:(NSDictionary<NSNumber *, NSValue *> *)currentBounds;

@end

@protocol M1WindowLayoutProvider <NSObject>
@property (nonatomic, readonly) BOOL accessibilityTrusted;
- (nullable M1WindowLayoutSnapshot *)captureLayoutExcludingPIDs:(NSSet<NSNumber *> *)pids;
- (BOOL)moveWindow:(M1WindowInfo *)window
         fromFrame:(CGRect)currentFrame
           toFrame:(CGRect)targetFrame
             error:(NSError * _Nullable * _Nullable)error;
@end

// 生产实现：CGWindowList 采集 + Accessibility 搬窗。
@interface M1WindowLayoutAXProvider : NSObject <M1WindowLayoutProvider>
@end

@interface M1WindowLayoutRestorer : NSObject

- (instancetype)initWithProvider:(id<M1WindowLayoutProvider>)provider;

// 返回摘要：captured / planned / restored / failed / skipped / trusted。
// AX 未授权时不尝试搬窗，summary.trusted = NO、skipped = planned。
- (NSDictionary *)restoreSnapshot:(M1WindowLayoutSnapshot *)snapshot
               disabledDisplayIDs:(NSSet<NSNumber *> *)disabledDisplayIDs;

@end

NS_ASSUME_NONNULL_END
