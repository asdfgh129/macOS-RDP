//
//  CGVirtualDisplaySPI.h
//  P0-TahoeProbe
//
//  CoreGraphics 私有类 CGVirtualDisplay* 的本地重声明。
//
//  注意：这里只声明 @protocol，不声明 @interface。这样编译器只会生成
//  objc_msgSend 调用，不会在链接期引用 OBJC_CLASS_$_CGVirtualDisplay* 符号，
//  即使目标系统上私有符号未导出、或 SDK 头文件缺失，工程也能正常编译链接。
//
//  声明来源（两份互相印证）：
//   1. Stengo/DeskPad  DeskPad/CGVirtualDisplayPrivate.h  (Khaos Tian, 2021)
//   2. Okle42/SideScreen42  Sources/CVirtualDisplay/include/CGVirtualDisplay.h
//      （作者在 macOS 27.0.1 上用 Objective-C runtime 逐项复核过）
//  两份在 macOS 15 / 26 / 27 上的 selector 与属性名一致。
//
//  P0 的 `probe` 子命令会在目标机上重新 dump 一次真实 selector 列表，
//  用来确认 Intel + Tahoe 26.7.x 上这些签名没有漂移。
//

#ifndef CGVirtualDisplaySPI_h
#define CGVirtualDisplaySPI_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
// setQueue: 用到 dispatch_queue_t，显式引入，别依赖 Foundation 的间接传递包含。
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN

@protocol VD_Mode <NSObject>
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(double)refreshRate;
@end

@protocol VD_Settings <NSObject>
- (instancetype)init;
- (void)setModes:(NSArray *)modes;
- (NSArray *)modes;
- (void)setHiDPI:(unsigned int)hiDPI;
- (unsigned int)hiDPI;
// macOS 27 上新增，老系统可能不响应；一律用 respondsToSelector 保护。
- (void)setRotation:(unsigned int)rotation;
@end

@protocol VD_Descriptor <NSObject>
- (instancetype)init;
- (void)setQueue:(dispatch_queue_t)queue;
- (void)setName:(NSString *)name;
- (void)setSizeInMillimeters:(CGSize)size;
- (void)setMaxPixelsWide:(unsigned int)w;
- (void)setMaxPixelsHigh:(unsigned int)h;
- (void)setVendorID:(unsigned int)v;
- (void)setProductID:(unsigned int)p;
- (void)setSerialNum:(unsigned int)s;
@end

@protocol VD_Display <NSObject>
- (nullable instancetype)initWithDescriptor:(id)descriptor;
- (CGDirectDisplayID)displayID;
- (BOOL)applySettings:(id)settings;
- (unsigned int)hiDPI;
- (NSArray *)modes;
@end

// 显式 dlopen 承载私有类的 framework，再按名字解析 Class。
// 返回 YES 表示四个类全部可解析。
BOOL VDLoadPrivateClasses(void);

// 按名字取 Class，未加载返回 nil。
Class _Nullable VDClass(NSString *name);

// dump 某个类的实例方法 selector 名（含父类不计），用于跨版本签名比对。
NSArray<NSString *> * _Nullable VDSelectorDump(NSString *className);

// 判断对象是否响应 selector（私有属性在个别版本会改名，不要直接裸调）。
BOOL VDResponds(id object, SEL selector);

NS_ASSUME_NONNULL_END

#endif /* CGVirtualDisplaySPI_h */
