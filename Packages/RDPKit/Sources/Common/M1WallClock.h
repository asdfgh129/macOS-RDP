//
//  M1WallClock.h
//  M1-Skeleton
//
//  跨机打点用的 Unix epoch 时钟。CACurrentMediaTime 是进程内单调时钟，
//  不能跨机相减；A-02 必须在采集/渲染两端用同一个 epoch 时基。
//

#ifndef M1WallClock_h
#define M1WallClock_h

#include <stdint.h>
#include <time.h>

static inline uint64_t M1WallClockUs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

#endif /* M1WallClock_h */
