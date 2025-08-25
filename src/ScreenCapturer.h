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

@end

NS_ASSUME_NONNULL_END

#endif /* ScreenCapturer_h */
