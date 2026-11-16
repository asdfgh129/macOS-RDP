//
//  P1Coordinate.m
//  P1-ClientProbe
//

#import "P1Coordinate.h"

CGRect P1QuartzRectFromNSRect(CGRect nsRect, CGFloat mainDisplayHeight) {
    return CGRectMake(nsRect.origin.x,
                      mainDisplayHeight - nsRect.origin.y - nsRect.size.height,
                      nsRect.size.width, nsRect.size.height);
}

CGRect P1NSRectFromQuartzRect(CGRect quartzRect, CGFloat mainDisplayHeight) {
    return CGRectMake(quartzRect.origin.x,
                      mainDisplayHeight - quartzRect.origin.y - quartzRect.size.height,
                      quartzRect.size.width, quartzRect.size.height);
}

CGPoint P1MapPoint(CGPoint p, CGRect fromRect, CGRect toRect) {
    if (CGRectIsEmpty(fromRect)) return toRect.origin;
    CGFloat rx = (p.x - fromRect.origin.x) / fromRect.size.width;
    CGFloat ry = (p.y - fromRect.origin.y) / fromRect.size.height;
    return CGPointMake(toRect.origin.x + rx * toRect.size.width,
                       toRect.origin.y + ry * toRect.size.height);
}

CGRect P1MapRect(CGRect r, CGRect fromRect, CGRect toRect) {
    CGPoint o = P1MapPoint(r.origin, fromRect, toRect);
    if (CGRectIsEmpty(fromRect)) return CGRectMake(o.x, o.y, 0, 0);
    return CGRectMake(o.x, o.y,
                      r.size.width / fromRect.size.width * toRect.size.width,
                      r.size.height / fromRect.size.height * toRect.size.height);
}