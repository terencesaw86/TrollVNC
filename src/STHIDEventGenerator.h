/*
 * Copyright (C) 2015 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "IOKitSPI.h"
#import <CoreGraphics/CGGeometry.h>

#pragma mark -

// Keys for `sendEventStream:`.
static NSString *const TopLevelEventInfoKey = @"eventInfo";
static NSString *const SecondLevelEventsKey = @"events";
static NSString *const HIDEventInputType = @"inputType";
static NSString *const HIDEventTimeOffsetKey = @"timeOffset";
static NSString *const HIDEventTouchesKey = @"touches";
static NSString *const HIDEventPhaseKey = @"phase";
static NSString *const HIDEventInterpolateKey = @"interpolate";
static NSString *const HIDEventTimestepKey = @"timestep";
static NSString *const HIDEventCoordinateSpaceKey = @"coordinateSpace";
static NSString *const HIDEventStartEventKey = @"startEvent";
static NSString *const HIDEventEndEventKey = @"endEvent";
static NSString *const HIDEventTouchIDKey = @"id";
static NSString *const HIDEventPressureKey = @"pressure";
static NSString *const HIDEventXKey = @"x";
static NSString *const HIDEventYKey = @"y";
static NSString *const HIDEventTwistKey = @"twist";
static NSString *const HIDEventMaskKey = @"mask";
static NSString *const HIDEventMajorRadiusKey = @"majorRadius";
static NSString *const HIDEventMinorRadiusKey = @"minorRadius";
static NSString *const HIDEventFingerKey = @"finger";

// Values for HIDEventInputType.
static NSString *const HIDEventInputTypeHand = @"hand";
static NSString *const HIDEventInputTypeFinger = @"finger";
static NSString *const HIDEventInputTypeStylus = @"stylus";

// Values for HIDEventCoordinateSpaceKey.
static NSString *const HIDEventCoordinateSpaceTypeGlobal = @"global";
static NSString *const HIDEventCoordinateSpaceTypeContent = @"content";

static NSString *const HIDEventInterpolationTypeLinear = @"linear";
static NSString *const HIDEventInterpolationTypeSimpleCurve = @"simpleCurve";

// Values for HIDEventPhaseKey.
static NSString *const HIDEventPhaseBegan = @"began";
static NSString *const HIDEventPhaseStationary = @"stationary";
static NSString *const HIDEventPhaseMoved = @"moved";
static NSString *const HIDEventPhaseEnded = @"ended";
static NSString *const HIDEventPhaseCanceled = @"canceled";

// Values for touch counts, etc, to keep debug code in sync

static NSUInteger const HIDMaxTouchCount = 30;

#pragma mark -

#define SZ_USLEEP(us)                                                                                                  \
    {                                                                                                                  \
        struct timeval ___delay___;                                                                                    \
        ___delay___.tv_sec = 0;                                                                                        \
        if (((int)us) > (USEC_PER_SEC)) {                                                                              \
            ___delay___.tv_sec = ((int)us) / (USEC_PER_SEC);                                                           \
        }                                                                                                              \
        ___delay___.tv_usec = ((int)us) % (USEC_PER_SEC);                                                              \
        select(0, NULL, NULL, NULL, &___delay___);                                                                     \
    }

__used NS_INLINE void STAccurateSleep(NSTimeInterval seconds) {
    int us = (int)round(seconds * USEC_PER_SEC);
    if (us <= 0) {
        us = 1;
    }
    int s = us / USEC_PER_SEC;
    us %= USEC_PER_SEC;
    if (0 != s) {
        for (int i = 0; i < s; ++i) {
            struct timeval tv;
            tv.tv_sec = 1;
            tv.tv_usec = 0;
            select(0, NULL, NULL, NULL, &tv);
        }
    }
    SZ_USLEEP(us);
}

#pragma mark -

@interface STHIDEventGenerator : NSObject

+ (STHIDEventGenerator *)sharedGenerator;

/* MARK: --- Touches --- */

- (void)touchDown:(CGPoint)location;
- (void)liftUp:(CGPoint)location;
- (void)touchDown:(CGPoint)location touchCount:(NSUInteger)count;
- (void)liftUp:(CGPoint)location touchCount:(NSUInteger)count;

/* MARK: --- Stylus --- */

- (void)stylusDownAtPoint:(CGPoint)location
             azimuthAngle:(CGFloat)azimuthAngle
            altitudeAngle:(CGFloat)altitudeAngle
                 pressure:(CGFloat)pressure;

- (void)stylusMoveToPoint:(CGPoint)location
             azimuthAngle:(CGFloat)azimuthAngle
            altitudeAngle:(CGFloat)altitudeAngle
                 pressure:(CGFloat)pressure;

- (void)stylusUpAtPoint:(CGPoint)location;

// sync 0.05
- (void)stylusTapAtPoint:(CGPoint)location
            azimuthAngle:(CGFloat)azimuthAngle
           altitudeAngle:(CGFloat)altitudeAngle
                pressure:(CGFloat)pressure;

/* MARK: --- Taps --- */

// sync 0.05
- (void)tap:(CGPoint)location;

// sync 0.05 + 0.15 + 0.05 = 0.25
- (void)doubleTap:(CGPoint)location;

// sync 0.05
- (void)twoFingerTap:(CGPoint)location;

// sync 0.05
- (void)threeFingerTap:(CGPoint)location;

// sync 0.05 * tapCount + MAX(0.15, delay) * (tapCount - 1)
- (void)sendTaps:(NSUInteger)tapCount
            location:(CGPoint)location
     numberOfTouches:(NSUInteger)touchCount
    delayBetweenTaps:(NSTimeInterval)delay;

/* MARK: --- Long Press --- */

// async 2.0
- (void)longPress:(CGPoint)location;

/* MARK: --- Drags --- */

// sync seconds
- (void)dragLinearWithStartPoint:(CGPoint)startLocation endPoint:(CGPoint)endLocation duration:(NSTimeInterval)seconds;

// sync seconds
- (void)dragCurveWithStartPoint:(CGPoint)startLocation endPoint:(CGPoint)endLocation duration:(NSTimeInterval)seconds;

/* MARK: --- Pinches --- */

// sync seconds
- (void)pinchLinearInBounds:(CGRect)bounds scale:(CGFloat)scale angle:(CGFloat)angle duration:(NSTimeInterval)seconds;

/* MARK: --- Event Stream --- */

// async calculated
- (void)sendEventStream:(NSDictionary *)eventInfo;

/* MARK: --- ASCII Keyboard --- */

// sync 0.05
- (void)keyPress:(NSString *)character;

- (void)keyDown:(NSString *)character;
- (void)keyUp:(NSString *)character;

/* MARK: --- Home Button --- */

// sync 0.05
- (void)menuPress;

// sync 0.05 + 0.15 + 0.05 = 0.25
- (void)menuDoublePress;

// async 2.0
- (void)menuLongPress;

- (void)menuDown;
- (void)menuUp;

/* MARK: --- Power Button --- */

// sync 0.05
- (void)powerPress;

// sync 0.05 + 0.15 + 0.05 = 0.25
- (void)powerDoublePress;

// sync 0.05 + 0.15 + 0.05 + 0.15 + 0.05 = 0.45
- (void)powerTriplePress;

// async 2.0
- (void)powerLongPress;

- (void)powerDown;
- (void)powerUp;

/* MARK: --- Home + Power Button --- */

// sync 0.05
- (void)snapshotPress;

// sync 0.05
- (void)toggleOnScreenKeyboard;

// sync 0.05
- (void)toggleSpotlight;

/* MARK: --- Mute Trigger --- */

// sync 0.05
- (void)mutePress;

- (void)muteDown;
- (void)muteUp;

/* MARK: --- Volume Buttons --- */

// sync 0.05
- (void)volumeIncrementPress;

- (void)volumeIncrementDown;
- (void)volumeIncrementUp;

// sync 0.05
- (void)volumeDecrementPress;

- (void)volumeDecrementDown;
- (void)volumeDecrementUp;

/* MARK: --- Brightness Buttons --- */

// sync 0.05
- (void)displayBrightnessIncrementPress;

- (void)displayBrightnessIncrementDown;
- (void)displayBrightnessIncrementUp;

// sync 0.05
- (void)displayBrightnessDecrementPress;

- (void)displayBrightnessDecrementDown;
- (void)displayBrightnessDecrementUp;

/* MARK: --- Accelerometer --- */

// async 2.0
- (void)shakeIt;

/* MARK: --- Other Consumer Usages --- */

// sync 0.05
- (void)otherConsumerUsagePress:(uint32_t)usage;
- (void)otherConsumerUsageDown:(uint32_t)usage;
- (void)otherConsumerUsageUp:(uint32_t)usage;

// sync 0.05
- (void)otherPage:(uint32_t)page usagePress:(uint32_t)usage;
- (void)otherPage:(uint32_t)page usageDown:(uint32_t)usage;
- (void)otherPage:(uint32_t)page usageUp:(uint32_t)usage;

/* MARK: --- Recycle --- */

- (void)releaseEveryKeys;

/* MARK: --- Keyboard Interruption --- */

- (void)hardwareLock;
- (void)hardwareUnlock;

@end
