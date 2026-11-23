//
//  P1Coordinate.h
//  P1-ClientProbe
//
//  纯函数坐标变换：NSScreen（左下原点）↔ Quartz（左上原点），
//  以及窗口坐标 → 目标虚拟屏坐标的归一化映射。
//  不依赖 AppKit/WindowServer，可纯单测。对应 DESIGN.md §5.4。
//

#import <CoreGraphics/CoreGraphics.h>

#ifndef P1Coordinate_h
#define P1Coordinate_h

// mainDisplayHeight = 主屏 Quartz 高度（CGDisplayBounds(CGMainDisplayID()).size.height）
CGRect P1QuartzRectFromNSRect(CGRect nsRect, CGFloat mainDisplayHeight);
CGRect P1NSRectFromQuartzRect(CGRect quartzRect, CGFloat mainDisplayHeight);

// fromRect 内一点按比例映射到 toRect（处理负坐标原点与混合缩放）。
// fromRect 为空时返回 toRect.origin（边界防御，调用方不应传空矩形）。
CGPoint P1MapPoint(CGPoint p, CGRect fromRect, CGRect toRect);
CGRect P1MapRect(CGRect r, CGRect fromRect, CGRect toRect);

#endif /* P1Coordinate_h */