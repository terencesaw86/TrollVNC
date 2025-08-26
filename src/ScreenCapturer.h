#ifndef ScreenCapturer_h
#define ScreenCapturer_h

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScreenCapturer : NSObject

+ (instancetype)sharedCapturer;
+ (NSDictionary *)sharedRenderProperties;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

- (void)startCaptureWithFrameHandler:(void (^)(CMSampleBufferRef sampleBuffer))frameHandler;
- (void)endCapture;

/**
 Set preferred frame rate range for the CADisplayLink driving capture.
 Pass 0 to any of the arguments to leave it unspecified (system default).
 On iOS 15+, preferredFrameRateRange will be used; on iOS 14, preferredFramesPerSecond uses maxFps.
 */
- (void)setPreferredFrameRateWithMin:(NSInteger)minFps preferred:(NSInteger)preferredFps max:(NSInteger)maxFps;

@end

NS_ASSUME_NONNULL_END

#endif /* ScreenCapturer_h */
