
#pragma once

#include "kextdaemon.h"

#include <mach/mach_time.h>

extern BOOL is_perf;
extern BOOL is_dumping;
extern double start, end, t1, t2, t3, t4, outerstart, outerend, outersum, outernum;
extern NSMutableArray* logs;

#define GET_TIME() (mach_absolute_time() / 1000.0);
#define LOG(format, ...) if (!is_dumping) { if(is_perf) {[logs addObject: [NSString stringWithFormat:format, ##__VA_ARGS__]];} else {NSLog(format, ##__VA_ARGS__); } }

void debug_log_old(mouse_event_t *event, CGPoint currentPos, float calcx, float calcy);
void debug_register_event(mouse_event_t *event);
void debug_end();
