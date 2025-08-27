#ifndef ScreenCapturer_h
#define ScreenCapturer_h

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 ScreenCapturer
 ----------------
 A singleton that captures the device screen into an IOSurface and produces
 CMSampleBufferRef frames on a CADisplayLink-driven cadence. Intended for use
 by encoders/streamers that require CVPixelBuffer-backed sample buffers.

 Threading & lifetime:
 - startCapture/endCapture must be called on the main thread (internally uses CADisplayLink on main run loop).
 - The provided frame handler is invoked on the main thread.
 - ARC only.

 Performance & format:
 - Uses IOSurface + CoreAnimation render server to copy screen contents.
 - Zero-copy wrapping via CVPixelBufferCreateWithIOSurface.
 - Pixel format is ARGB as defined by sharedRenderProperties.

 Debug stats (DEBUG builds only):
 - Average FPS is periodically logged over a configurable window.
 - Instantaneous FPS is computed from CADisplayLink.duration and can be smoothed with EMA.
 */
@interface ScreenCapturer : NSObject

/** Returns the shared singleton instance. */
+ (instancetype)sharedCapturer;

/**
 Returns the IOSurface property dictionary used to create screen-sized surfaces
 compatible with the current device configuration (size/orientation/format).
 Consumers can use this to allocate compatible IOSurfaces.
 */
+ (NSDictionary *)sharedRenderProperties;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/**
 Start screen capture. The frame handler will be called on the main thread for
 each captured frame with a CMSampleBufferRef referencing a CVPixelBuffer backed
 by the current IOSurface.

 If capture is already active, this replaces the frame handler for subsequent frames
 without restarting the underlying CADisplayLink.
 */
- (void)startCaptureWithFrameHandler:(void (^)(CMSampleBufferRef sampleBuffer))frameHandler;

/**
 Stop screen capture and release internal resources (CADisplayLink, IOSurface).
 Safe to call multiple times.
 */
- (void)endCapture;

/**
 Set preferred frame rate range for the CADisplayLink driving capture.
 Pass 0 to any of the arguments to leave it unspecified (system default).
 On iOS 15+, preferredFrameRateRange will be used; on iOS 14, preferredFramesPerSecond uses maxFps.
 */
- (void)setPreferredFrameRateWithMin:(NSInteger)minFps preferred:(NSInteger)preferredFps max:(NSInteger)maxFps;

/**
 Configure the logging window used for average capture FPS reporting (DEBUG only).
 Defaults to 5.0 seconds. Values <= 0 disable periodic FPS logging.
 */
- (void)setStatsLogWindowSeconds:(NSTimeInterval)seconds;

/**
 Configure smoothing factor (alpha) for instantaneous FPS based on CADisplayLink.duration (DEBUG only).
 Uses exponential moving average: ema = alpha * current + (1 - alpha) * ema.
 Defaults to 0.2; valid range [0.0, 1.0]. Out-of-range values are clamped.
 */
- (void)setInstantFpsSmoothingFactor:(double)alpha;

@end

NS_ASSUME_NONNULL_END

#endif /* ScreenCapturer_h */
