#import <PreferencePanes/PreferencePanes.h>
#import <AppKit/NSTextView.h>
#import <Cocoa/Cocoa.h>

@interface SmoothMousePrefPane : NSPreferencePane {
@private
    IBOutlet NSMenu         *buttonMenu;

    IBOutlet NSButton       *enableForMouse;
    IBOutlet NSPopUpButton  *accelerationCurveMouse;
	IBOutlet NSSlider		*velocityForMouse;

    IBOutlet NSButton       *enableForTrackpad;
    IBOutlet NSPopUpButton  *accelerationCurveTrackpad;
	IBOutlet NSSlider		*velocityForTrackpad;

    /* deprecated */
	IBOutlet NSButton		*switchOnOff;
	IBOutlet NSButton		*startAtLogin;
	IBOutlet NSTextField	*status;
}

- (void)mainViewDidLoad;

- (IBAction)changeVelocity:(id) sender;
- (IBAction)changeAccelerationCurve:(id) sender;
- (IBAction)pressEnableDisableMouse:(id) sender;
- (IBAction)pressEnableDisableTrackpad:(id) sender;

- (void)startOrStopDaemon;
- (BOOL)isDaemonRunning;
- (BOOL)startDaemon;
- (BOOL)stopDaemon;

- (BOOL)startAtLoginEnabled;
- (BOOL)putLaunchdPlist;
- (BOOL)deleteLaunchdPlist;

- (double)getVelocityForMouse;
- (double)getVelocityForTrackpad;
- (BOOL)getMouseEnabled;
- (BOOL)getTrackpadEnabled;
- (NSString *)getAccelerationCurveForMouse;
- (NSString *)getAccelerationCurveForTrackpad;
- (BOOL)saveVelocityForMouse:(double) valueMouse andTrackpad:(double) valueTrackpad;
- (BOOL)saveMouseEnabled:(BOOL) value;
- (BOOL)saveTrackpadEnabled:(BOOL) value;
- (BOOL)saveAccelerationCurveForMouse:(NSString *) value;
- (BOOL)saveAccelerationCurveForTrackpad:(NSString *) value;

- (void)restartDaemonIfRunning;
@end
