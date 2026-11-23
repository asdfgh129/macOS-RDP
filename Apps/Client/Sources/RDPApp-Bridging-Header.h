//
//  RDPApp-Bridging-Header.h
//  RDPApp
//
//  D-02：Swift 主工程 + ObjC 桥。此头把 RDPKit / ProtocolCodec 的公共接口暴露给 Swift。
//  第 3 轮起收编：配对 / 接管 / 会话 / 输入 / 解码预热 / 零拷贝上屏视图。
//

#ifndef RDPApp_Bridging_Header_h
#define RDPApp_Bridging_Header_h

#import <CoreGraphics/CoreGraphics.h>
#import "M1Pairing.h"
#import "M1Takeover.h"
#import "M1SessionCoordinator.h"
#import "M1DriverLogic.h"
#import "M1InputLogic.h"
#import "M1FrameReceiver.h"
#import "M1FrameView.h"

#endif /* RDPApp_Bridging_Header_h */
