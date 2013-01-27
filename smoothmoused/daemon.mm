#import <IOKit/IODataQueueClient.h>
#import <IOKit/kext/KextManager.h>
#import <mach/mach.h>
#include <mach/mach_init.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <sched.h>
#include <sys/sysctl.h>

#import "kextdaemon.h"
#import "constants.h"
#import "debug.h"
#import "mouse.h"
#import "accel.h"

#define KEXT_CONNECT_RETRIES (3)
#define SUPERVISOR_SLEEP_TIME_USEC (500000)

BOOL is_debug = 0;
BOOL is_memory = 0;
BOOL is_timings = 0;
BOOL is_dumping = 0;

static BOOL mouse_enabled;
static BOOL trackpad_enabled;
double velocity_mouse;
double velocity_trackpad;
AccelerationCurve curve_mouse;
AccelerationCurve curve_trackpad;
Driver driver;

double start, end, e1, e2, mhs, mhe, outerstart, outerend, outersum = 0, outernum = 0;
NSMutableArray* logs = [[NSMutableArray alloc] init];

@interface SmoothMouseDaemon : NSObject {
@private
    BOOL connected;
    pthread_t mouseEventThreadID;
    io_service_t service;
	io_connect_t connect;
	IODataQueueMemory *queueMappedMemory;
	mach_port_t	recvPort;
	uint32_t dataSize;
	mach_vm_address_t address;
    mach_vm_size_t size;
}

-(id)init;
-(oneway void) release;

-(BOOL) loadSettings;
-(BOOL) loadDriver;
-(BOOL) connectToDriver;
-(BOOL) configureDriver;
-(BOOL) disconnectFromDriver;
-(BOOL) isActive;

@end

/* -------------------------------------------------------------------------- */

@implementation SmoothMouseDaemon

-(id)init
{
	self = [super init];

    connected = NO;

	BOOL settingsOK = [self loadSettings];
    if (!settingsOK) {
        NSLog(@"settings doesn't exist (please open preference pane)");
        [self dealloc];
        return nil;
    }

    if (!is_debug) {
        if (!mouse_enabled && !trackpad_enabled) {
            NSLog(@"neither mouse nor trackpad is enabled");
            [self dealloc];
            return nil;
        }
    } else {
        mouse_enabled = 1;
        trackpad_enabled = 1;
    }

	return self;
}

-(AccelerationCurve) getAccelerationCurveFromDict:(NSDictionary *)dictionary withKey:(NSString *)key {
    NSString *value;
    value = [dictionary valueForKey:key];
	if (value) {
        if ([value compare:@"Windows"] == NSOrderedSame) {
            return ACCELERATION_CURVE_WINDOWS;
        }
	}
    return ACCELERATION_CURVE_LINEAR;
}

-(BOOL) loadSettings
{
	NSString *file = [NSHomeDirectory() stringByAppendingPathComponent: PREFERENCES_FILENAME];
	NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:file];

	if (!dict) {
		NSLog(@"cannot open file %@", file);
        return NO;
	}

    NSLog(@"found %@", file);

    NSNumber *value;

    value = [dict valueForKey:SETTINGS_MOUSE_ENABLED];
	if (value) {
		mouse_enabled = [value boolValue];
	} else {
		return NO;
	}

    value = [dict valueForKey:SETTINGS_TRACKPAD_ENABLED];
	if (value) {
		trackpad_enabled = [value boolValue];
	} else {
		return NO;
	}

	value = [dict valueForKey:SETTINGS_MOUSE_VELOCITY];
	if (value) {
        velocity_mouse = [value doubleValue];
	} else {
		velocity_mouse = 1.0;
	}

    value = [dict valueForKey:SETTINGS_TRACKPAD_VELOCITY];
	if (value) {
		velocity_trackpad = [value doubleValue];
	} else {
		velocity_trackpad = 1.0;
	}

    value = [dict valueForKey:SETTINGS_DRIVER];
	if (value) {
		driver = (Driver) [value intValue];
	} else {
		driver = (Driver) SETTINGS_DRIVER_DEFAULT;
	}

    curve_mouse = [self getAccelerationCurveFromDict:dict withKey:SETTINGS_MOUSE_ACCELERATION_CURVE];
    curve_trackpad = [self getAccelerationCurveFromDict:dict withKey:SETTINGS_TRACKPAD_ACCELERATION_CURVE];

    return YES;
}

-(BOOL) loadDriver
{
	NSString *kextID = @"com.cyberic.smoothmouse";
	return (kOSReturnSuccess == KextManagerLoadKextWithIdentifier((CFStringRef)kextID, NULL));
}

-(BOOL) connectToDriver
{
    if (!connected) {
        kern_return_t error;

        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("com_cyberic_SmoothMouse"));
        if (service == IO_OBJECT_NULL) {
            NSLog(@"IOServiceGetMatchingService() failed");
            if ([self loadDriver]) {
                NSLog(@"driver is loaded manually, try again");
                service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("com_cyberic_SmoothMouse"));
                if (service == IO_OBJECT_NULL) {
                    goto error;
                }
            } else {
                NSLog(@"cannot load driver manually");
            }

            goto error;
        }

        error = IOServiceOpen(service, mach_task_self(), 0, &connect);
        if (error) {
            NSLog(@"IOServiceOpen() failed (kext is busy)");
            IOObjectRelease(service);
            goto error;
        }

        IOObjectRelease(service);

        recvPort = IODataQueueAllocateNotificationPort();
        if (MACH_PORT_NULL == recvPort) {
            NSLog(@"IODataQueueAllocateNotificationPort returned a NULL mach_port_t\n");
            goto error;
        }

        error = IOConnectSetNotificationPort(connect, kIODefaultMemoryType, recvPort, 0);
        if (kIOReturnSuccess != error) {
            NSLog(@"IOConnectSetNotificationPort returned %d\n", error);
            goto error;
        }

        error = IOConnectMapMemory(connect, kIODefaultMemoryType, mach_task_self(), &address, &size, kIOMapAnywhere);
        if (kIOReturnSuccess != error) {
            NSLog(@"IOConnectMapMemory returned %d\n", error);
            goto error;
        }

        queueMappedMemory = (IODataQueueMemory *) address;
        dataSize = (uint32_t) size;

        [self configureDriver];

        int threadError = pthread_create(&mouseEventThreadID, NULL, &HandleMouseEventThread, self);
        if (threadError != 0)
        {
            NSLog(@"Failed to start mouse event thread");
        }

        initializeSystemMouseSettings(mouse_enabled, trackpad_enabled);

        connected = YES;
    }

	return YES;

error:
    return NO;
}

-(BOOL) configureDriver
{
    kern_return_t	kernResult;

    uint64_t scalarI_64[1];
    uint64_t scalarO_64;
    uint32_t outputCount = 1;

    uint32_t configuration = 0;

    if (mouse_enabled) {
        configuration |= 1 << 0;
    }

    if (trackpad_enabled) {
        configuration |= 1 << 1;
    }

    if (driver == DRIVER_QUARTZ_OLD) {
        configuration |= 1 << 2; // set compatibility mode in kernel
    }

    scalarI_64[0] = configuration;

    kernResult = IOConnectCallScalarMethod(connect,					// an io_connect_t returned from IOServiceOpen().
                                           kConfigureMethod,        // selector of the function to be called via the user client.
                                           scalarI_64,				// array of scalar (64-bit) input values.
                                           1,						// the number of scalar input values.
                                           &scalarO_64,				// array of scalar (64-bit) output values.
                                           &outputCount				// pointer to the number of scalar output values.
                                           );

    if (kernResult == KERN_SUCCESS) {
        NSLog(@"Driver configured successfully (%u)", (uint32_t) scalarO_64);
        return YES;
    }
	else {
		NSLog(@"Failed to configure driver");
        return NO;
    }
}

-(BOOL) disconnectFromDriver
{
    if (connected) {
        if (recvPort) {
            mach_port_destroy(mach_task_self(), recvPort);
        }

        int rv = pthread_join(mouseEventThreadID, NULL);
        if (rv != 0) {
            NSLog(@"Failed to wait for mouse event thread");
        }

        if (address) {
            IOConnectUnmapMemory(connect, kIODefaultMemoryType, mach_task_self(), address);
        }

        if (connect) {
            IOServiceClose(connect);
        }

        connected = NO;
    }

    return YES;
}

-(oneway void) release
{
    [self disconnectFromDriver];
	[super release];
}

BOOL set_high_prio_pthread() {
    struct sched_param sp;

    memset(&sp, 0, sizeof(struct sched_param));

    sp.sched_priority = sched_get_priority_max(SCHED_RR);

    if (pthread_setschedparam(pthread_self(), SCHED_RR, &sp)  == -1) {
        NSLog(@"call to pthread_setschedparam failed");
        return NO;
    }

    NSLog(@"Thread prio set to highest (%u)", sp.sched_priority);

    return YES;
}

inline uint64_t convert_from_nanos_to_mach_timebase(uint64_t nanos, mach_timebase_info_data_t *info)
{
    Float64 timebase = static_cast<Float64>(info->denom) / static_cast<Float64>(info->numer);
    uint64_t mach_time = nanos * timebase;
    //NSLog(@"convert_from_nanos_to_mach_timebase: %llu => %llu", nanos, mach_time);
    return mach_time;
}

inline uint64_t convert_from_mach_timebase_to_nanos(uint64_t mach_time, mach_timebase_info_data_t *info)
{
    Float64 timebase = static_cast<Float64>(info->numer) / static_cast<Float64>(info->denom);
    uint64_t nanos = mach_time * timebase;
    //NSLog(@"convert_from_mach_timebase_to_nanos: %llu => %llu", mach_time, nanos);
    return nanos;
}

BOOL set_realtime_prio() {
    mach_timebase_info_data_t info;
    kern_return_t kret = mach_timebase_info(&info);
    if (kret != KERN_SUCCESS) {
        NSLog(@"call to mach_timebase_info failed: %d", kret);
    }

    /* See:
     http://developer.apple.com/library/mac/#documentation/Darwin/Conceptual/KernelProgramming/scheduler/scheduler.html
     http://developer.apple.com/library/mac/#qa/qa1398/_index.html
     */

#define MS_TO_NANOS(ms) ((ms) * 1000000)

    struct thread_time_constraint_policy ttcpolicy;
    // 500hz mouse = 2ms
    ttcpolicy.period        = (uint32_t) convert_from_nanos_to_mach_timebase(MS_TO_NANOS(2), &info);
    ttcpolicy.computation   = (uint32_t) convert_from_nanos_to_mach_timebase(50000, &info);
    ttcpolicy.constraint    = (uint32_t) convert_from_nanos_to_mach_timebase(200000, &info);
    ttcpolicy.preemptible   = 1;

#undef MS_TO_NANOS

    NSLog(@"period: %u, computation: %u, constraint: %u (all in mach timebase), preemtible: %u",
          ttcpolicy.period,
          ttcpolicy.computation,
          ttcpolicy.constraint,
          ttcpolicy.preemptible);

    thread_port_t thread_port = pthread_mach_thread_np(pthread_self());

    kret = thread_policy_set(thread_port,
                             THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t) &ttcpolicy,
                             THREAD_TIME_CONSTRAINT_POLICY_COUNT);

    if (kret != KERN_SUCCESS) {
        NSLog(@"call to thread_policy_set failed: %d", kret);
        return NO;
    }

    NSLog(@"Time constraint policy set");

    return YES;
}

void *HandleMouseEventThread(void *instance)
{
    SmoothMouseDaemon *self = (SmoothMouseDaemon *) instance;

    kern_return_t error;

	char *buf = (char *)malloc(self->dataSize);
	if (!buf) {
		NSLog(@"malloc error");
		return NULL;
	}

    set_high_prio_pthread();
    set_realtime_prio();

    (void) mouse_init();

    static int counter = 0;
    while (IODataQueueWaitForAvailableData(self->queueMappedMemory, self->recvPort) == kIOReturnSuccess) {
        outerend = GET_TIME();
        int numPackets = 0;
        while (IODataQueueDataAvailable(self->queueMappedMemory)) {
            start = GET_TIME();
            numPackets++;
            counter++;
            error = IODataQueueDequeue(self->queueMappedMemory, buf, &(self->dataSize));
            mouse_event_t *mouse_event = (mouse_event_t *) buf;
            if (!error) {
                mhs = GET_TIME();
                mouse_handle(mouse_event);
                mhe = GET_TIME();
            } else {
                LOG(@"IODataQueueDequeue() failed");
            }
            end = GET_TIME();
            if (is_timings) {
                LOG(@"outer: %f, inner: %f, post event: %f, (mouse_handle): %f, seqnum: %llu, data entries handled: %d", outerend-outerstart, end-start, e2-e1, mhe-mhs, mouse_event->seqnum, numPackets);
            }
        }

        if (outerstart != 0 && outerend != 0) {
            outernum += 1;
            outersum += (outerend-outerstart);
        }

        outerstart = GET_TIME();
    }

	free(buf);

    return NULL;
}

-(void) mainLoop
{
    int retries_left = KEXT_CONNECT_RETRIES;
    while(1) {
        BOOL active = [self isActive];
        if (active) {
            BOOL ok = [self connectToDriver];
            if (!ok) {
                NSLog(@"Failed to connect to kext (retries_left = %d)", retries_left);
                if (retries_left < 1) {
                    exit(-1);
                }
                retries_left--;
            } else {
                retries_left = KEXT_CONNECT_RETRIES;
                initializeSystemMouseSettings(mouse_enabled, trackpad_enabled);
            }
        } else {
            [self disconnectFromDriver];
        }
        usleep(SUPERVISOR_SLEEP_TIME_USEC);
    }
}

-(BOOL) isActive {
    BOOL active = NO;
    CFDictionaryRef sessionDict = CGSessionCopyCurrentDictionary();
    if (sessionDict) {
        const void *loggedIn = CFDictionaryGetValue(sessionDict, kCGSessionOnConsoleKey);
        CFRelease(sessionDict);
        if (loggedIn != kCFBooleanTrue) {
            active = NO;
        } else {
            active = YES;
        }
    }
    return active;
}

@end

void trap_signals(int sig)
{
    NSLog(@"trapped signal: %d", sig);
    if (is_debug) {
        debug_end();
    }
    restoreSystemMouseSettings();
    exit(-1);
}

const char *get_driver_string(int mouse_driver) {
    switch (mouse_driver) {
        case DRIVER_QUARTZ_OLD: return "QUARTZ_OLD";
        case DRIVER_QUARTZ: return "QUARTZ";
        case DRIVER_IOHID: return "IOHID";
        default: return "?";
    }
}

int main(int argc, char **argv)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    for(int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--debug") == 0) {
            is_debug = 1;
            NSLog(@"Debug mode enabled");
        }

        if (strcmp(argv[i], "--memory") == 0) {
            is_memory = 1;
            NSLog(@"Memory logging enabled");
        }

        if (strcmp(argv[i], "--timings") == 0) {
            is_timings = 1;
            NSLog(@"Timing logging enabled");
        }
    }

	SmoothMouseDaemon *daemon = [[SmoothMouseDaemon alloc] init];
    if (daemon == NULL) {
        NSLog(@"Daemon failed to initialize. BYE.");
        exit(-1);
    }

#if 0
    for (int i = 0; i != 31; ++i) {
        signal(i, trap_signals);
    }
#endif

    signal(SIGINT, trap_signals);
    signal(SIGKILL, trap_signals);
    signal(SIGTERM, trap_signals);

    NSLog(@"Mouse enabled: %d Mouse velocity: %f Mouse curve: %d",
          mouse_enabled,
          velocity_mouse,
          curve_mouse);
    
    NSLog(@"Trackpad enabled: %d Trackpad velocity: %f Trackpad curve: %d",
          trackpad_enabled,
          velocity_trackpad,
          curve_trackpad);
    
    NSLog(@"Driver: %s (%d)", get_driver_string(driver), driver);
    
	[daemon mainLoop];
    
	[daemon release];
	
	[pool release];
    
	return EXIT_SUCCESS;
}
