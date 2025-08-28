#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import "ScreenCapturer.h"
#import "IOKitSPI.h"
#import "IOSurfaceSPI.h"

#import <UIKit/UIDevice.h>
#import <UIKit/UIGeometry.h>
#import <UIKit/UIImage.h>
#import <UIKit/UIScreen.h>
#import <mach/mach.h>

#if DEBUG
#define SCLog(fmt, ...) NSLog((@"%s:%d " fmt "\r"), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__)
#else
#define SCLog(...)
#endif

typedef IOReturn IOMobileFramebufferReturn;
typedef void *IOMobileFramebufferRef;

#ifdef __cplusplus
extern "C" {
#endif

UIImage *_UICreateScreenUIImage(void);
CGImageRef UICreateCGImageFromIOSurface(IOSurfaceRef ioSurface);
void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y);

void IOMobileFramebufferGetDisplaySize(IOMobileFramebufferRef connect, CGSize *size);
IOMobileFramebufferReturn IOMobileFramebufferGetMainDisplay(IOMobileFramebufferRef *pointer);

#ifdef __cplusplus
}
#endif

@implementation ScreenCapturer {
    CADisplayLink *mDisplayLink;
    IOSurfaceRef mScreenSurface;
    uint32_t mSeed;
    void (^mFrameHandler)(CMSampleBufferRef sampleBuffer);
    NSInteger mMinFps;
    NSInteger mPreferredFps;
    NSInteger mMaxFps;
    // Stats configuration (effective in DEBUG only)
    NSTimeInterval mStatsWindowSeconds; // average FPS logging window
    double mInstFpsAlpha;               // EMA smoothing factor for instantaneous FPS
}

+ (instancetype)sharedCapturer {
    static ScreenCapturer *_inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _inst = [[self alloc] init];
        // Defaults for stats logging
#if DEBUG
        [_inst setStatsLogWindowSeconds:5.0];
        [_inst setInstantFpsSmoothingFactor:0.2];
#endif
    });
    return _inst;
}

+ (NSDictionary *)sharedRenderProperties {
    static NSDictionary *_renderProperties = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {

            int width, height;
#if TARGET_OS_SIMULATOR
            CGRect bounds = [[UIScreen mainScreen] bounds];
            CGFloat scale = [[UIScreen mainScreen] scale];
            CGSize screenSize = CGSizeMake(round(bounds.size.width * scale), round(bounds.size.height * scale));

            // Setup the width and height of the framebuffer for the device
            if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
                // iPhone frame buffer is Portrait
                width = screenSize.width;
                height = screenSize.height;
            } else {
                // iPad frame buffer is Landscape
                width = screenSize.height;
                height = screenSize.width;
            }
#else
            CGSize screenSize = CGSizeZero;
            static IOMobileFramebufferRef framebufferConnection = NULL;
            IOMobileFramebufferGetMainDisplay(&framebufferConnection);
            IOMobileFramebufferGetDisplaySize(framebufferConnection, &screenSize);

            width = (int)round(screenSize.width);
            height = (int)round(screenSize.height);
#endif

            // Pixel format for Alpha, Red, Green and Blue
            unsigned pixelFormat = 0x42475241; // 'ARGB'

            // 1 or 2 bytes per component
            int bytesPerComponent = sizeof(uint8_t);

            // 8 bytes per pixel
            int bytesPerElement = bytesPerComponent * 4;

            // Bytes per row (must be aligned)
            int bytesPerRow = (int)IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, bytesPerElement * width);

            // Properties included:
            // BytesPerElement, BytesPerRow, Width, Height, PixelFormat, AllocSize
            CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

            CFPropertyListRef colorSpacePropertyList = CGColorSpaceCopyPropertyList(colorSpace);
            CGColorSpaceRelease(colorSpace);

            _renderProperties = [NSDictionary
                dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:bytesPerElement], kIOSurfaceBytesPerElement,
                                             [NSNumber numberWithInt:bytesPerRow], kIOSurfaceBytesPerRow,
                                             [NSNumber numberWithInt:width], kIOSurfaceWidth,
                                             [NSNumber numberWithInt:height], kIOSurfaceHeight,
                                             [NSNumber numberWithUnsignedInt:pixelFormat], kIOSurfacePixelFormat,
                                             [NSNumber numberWithInt:bytesPerRow * height], kIOSurfaceAllocSize,
                                             CFBridgingRelease(colorSpacePropertyList), kIOSurfaceColorSpace, nil];

#if DEBUG
            SCLog(@"render properties %@", _renderProperties);
#endif
        }
    });

    return _renderProperties;
}
- (void)setPreferredFrameRateWithMin:(NSInteger)minFps preferred:(NSInteger)preferredFps max:(NSInteger)maxFps {
    // Normalize: if preferred is 0, but max/min provided, pick a reasonable default
    mMinFps = MAX(0, minFps);
    mMaxFps = MAX(0, maxFps);
    mPreferredFps = MAX(0, preferredFps);
    if (mPreferredFps == 0) {
        if (mMaxFps > 0)
            mPreferredFps = mMaxFps;
        else if (mMinFps > 0)
            mPreferredFps = mMinFps;
        else
            mPreferredFps = 0;
    }
    // If display link is already running, update it on main thread
    if (mDisplayLink) {
        void (^applyBlock)(void) = ^{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 150000
            if (@available(iOS 15.0, *)) {
                CAFrameRateRange range;
                range.minimum = (mMinFps > 0) ? mMinFps : 0.0;
                range.maximum = (mMaxFps > 0) ? mMaxFps : 0.0;
                range.preferred = (mPreferredFps > 0) ? mPreferredFps : 0.0;
                mDisplayLink.preferredFrameRateRange = range;
            } else
#endif
            {
                // iOS 14 path: only preferredFramesPerSecond is available, use max/preferred
                NSInteger setFps = (mMaxFps > 0) ? mMaxFps : mPreferredFps;
                mDisplayLink.preferredFramesPerSecond = (int)setFps; // 0 means system default
            }
        };
        if ([NSThread isMainThread])
            applyBlock();
        else
            dispatch_async(dispatch_get_main_queue(), applyBlock);
    }
}

- (void)setStatsLogWindowSeconds:(NSTimeInterval)seconds {
    mStatsWindowSeconds = seconds;
}

- (void)setInstantFpsSmoothingFactor:(double)alpha {
    if (alpha < 0.0)
        alpha = 0.0;
    if (alpha > 1.0)
        alpha = 1.0;
    mInstFpsAlpha = alpha;
}

- (void)createScreenSurfaceIfNeeded {
    if (!mScreenSurface) {
        NSDictionary *properties = [ScreenCapturer sharedRenderProperties];
        mScreenSurface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    }
}

+ (NSDictionary *)renderPropertiesInRect:(CGRect)rect {
    int width = (int)rect.size.width;
    int height = (int)rect.size.height;

    // Pixel format for Alpha, Red, Green and Blue
    unsigned pixelFormat = 0x42475241; // 'ARGB'

    // 1 or 2 bytes per component
    int bytesPerComponent = sizeof(uint8_t);

    // 8 bytes per pixel
    int bytesPerElement = bytesPerComponent * 4;

    // Bytes per row (must be aligned)
    int bytesPerRow = (int)IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, bytesPerElement * width);

    // Properties included:
    // BytesPerElement, BytesPerRow, Width, Height, PixelFormat, AllocSize
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

    CFPropertyListRef colorSpacePropertyList = CGColorSpaceCopyPropertyList(colorSpace);
    CGColorSpaceRelease(colorSpace);

    NSDictionary *properties = [NSDictionary
        dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:bytesPerElement], kIOSurfaceBytesPerElement,
                                     [NSNumber numberWithInt:bytesPerRow], kIOSurfaceBytesPerRow,
                                     [NSNumber numberWithInt:width], kIOSurfaceWidth, [NSNumber numberWithInt:height],
                                     kIOSurfaceHeight, [NSNumber numberWithUnsignedInt:pixelFormat],
                                     kIOSurfacePixelFormat, [NSNumber numberWithInt:bytesPerRow * height],
                                     kIOSurfaceAllocSize, CFBridgingRelease(colorSpacePropertyList),
                                     kIOSurfaceColorSpace, nil];

#if DEBUG
    SCLog(@"render properties %@", properties);
#endif

    return properties;
}

#pragma mark - Testing

+ (unsigned long)__getMemoryUsedInBytes {
    struct task_basic_info info;
    mach_msg_type_number_t size = sizeof(info);
    kern_return_t kerr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &size);
    if (kerr == KERN_SUCCESS) {
        return info.resident_size;
    } else {
        return 0;
    }
}

// Human-readable memory usage description based on __getMemoryUsedInBytes
+ (NSString *)__getMemoryUsageDescription {
    long long bytes = (long long)[self __getMemoryUsedInBytes];
    return [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleBinary];
}

- (BOOL)writeScreenUIImagePNGDataToFile:(NSString *)path {
    return [[self getScreenUIImagePNGData] writeToFile:path atomically:YES];
}

#pragma mark - Rendering

- (void)renderDisplayToScreenSurface:(IOSurfaceRef)dstSurface {
#if TARGET_OS_SIMULATOR
    CARenderServerRenderDisplay(0, CFSTR("LCD"), dstSurface, 0, 0);
#else
    CFRunLoopRef runLoop = CFRunLoopGetMain();

    static IOSurfaceRef srcSurface;
    static IOSurfaceAcceleratorRef accelerator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {
            srcSurface = IOSurfaceCreate((__bridge CFDictionaryRef)[ScreenCapturer sharedRenderProperties]);
            IOSurfaceAcceleratorCreate(kCFAllocatorDefault, nil, &accelerator);

            CFRunLoopSourceRef runLoopSource = IOSurfaceAcceleratorGetRunLoopSource(accelerator);
            CFRunLoopAddSource(runLoop, runLoopSource, kCFRunLoopDefaultMode);
        }
    });

    /// Fast ~20ms, sRGB, while the image is GOOD. Recommended.
    CARenderServerRenderDisplay(0, CFSTR("LCD"), srcSurface, 0, 0);
    IOSurfaceAcceleratorTransformSurface(accelerator, srcSurface, dstSurface, NULL, NULL, NULL, NULL, NULL);
#endif
}

- (void)updateDisplay:(CADisplayLink *)displayLink {
#if DEBUG
    __uint64_t beginAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif

    [self createScreenSurfaceIfNeeded];

    // Lock the surface
    IOSurfaceLock(mScreenSurface, 0, &mSeed);

    [self renderDisplayToScreenSurface:mScreenSurface];

    // Unlock the surface
    IOSurfaceUnlock(mScreenSurface, 0, &mSeed);

#if DEBUG
    __uint64_t endAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    static double s_lastLogAtMs = 0.0;
    static __uint64_t s_fpsWindowStartNs = 0;  // FPS window start (ns)
    static unsigned long long s_fpsFrames = 0; // Accumulated frames in window
    static __uint64_t s_prevFrameEndNs = 0;    // Fallback: previous frame end timestamp (ns) for instantaneous FPS
    static double s_instFpsEma = 0.0;          // Smoothed instantaneous FPS (EMA)

    // Accumulate frame count
    s_fpsFrames++;
    if (s_fpsWindowStartNs == 0) {
        s_fpsWindowStartNs = endAt;
    }

    // Instantaneous FPS sourced from CADisplayLink.duration; fallback to inter-frame delta if needed
    double instFps = 0.0;
    if (displayLink && displayLink.duration > 0.0) {
        instFps = 1.0 / displayLink.duration;
    } else if (s_prevFrameEndNs > 0) {
        __uint64_t deltaNs = endAt - s_prevFrameEndNs;
        if (deltaNs > 0)
            instFps = 1e9 / (double)deltaNs;
    }
    s_prevFrameEndNs = endAt;

    double nowMs = (double)endAt / NSEC_PER_MSEC;

    // EMA smoothing for instantaneous FPS
    if (instFps > 0.0) {
        double alpha = mInstFpsAlpha;
        s_instFpsEma = (s_instFpsEma == 0.0) ? instFps : (alpha * instFps + (1.0 - alpha) * s_instFpsEma);
    }

    // Periodic logging based on configurable window
    double windowMs = (mStatsWindowSeconds > 0.0) ? (mStatsWindowSeconds * 1000.0) : 0.0;
    if (windowMs > 0.0 && (nowMs - s_lastLogAtMs >= windowMs)) {
        double used = (double)(endAt - beginAt) / NSEC_PER_MSEC;
        double windowSec = (double)(endAt - s_fpsWindowStartNs) / 1e9; // ns -> s
        double fps = (windowSec > 0.0) ? (s_fpsFrames / windowSec) : 0.0;
        double instOut = (s_instFpsEma > 0.0) ? s_instFpsEma : instFps;
        SCLog(@"time elapsed %.2fms, capture fps %.2f (frames=%llu, window=%.2fs), inst fps %.2f, memory used %@", used,
              fps, s_fpsFrames, windowSec, instOut, [ScreenCapturer __getMemoryUsageDescription]);
        s_lastLogAtMs = nowMs;

        // Reset FPS window
        s_fpsWindowStartNs = endAt;
        s_fpsFrames = 0;
        s_instFpsEma = 0.0;
    }
#endif
}

- (UIImage *)getScreenUIImage {
#if DEBUG
    __uint64_t beginAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif

    UIImage *uiImage = _UICreateScreenUIImage();

#if DEBUG
    __uint64_t endAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double used = (double)(endAt - beginAt) / NSEC_PER_MSEC;
    SCLog(@"time elapsed %.2fms", used);
#endif

    return uiImage;
}

- (NSData *)getScreenUIImagePNGData {
#if DEBUG
    __uint64_t beginAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif
    // coding is slow: ~200ms
    NSData *data = UIImagePNGRepresentation([self getScreenUIImage]);
#if DEBUG
    __uint64_t endAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double used = (double)(endAt - beginAt) / NSEC_PER_MSEC;
    SCLog(@"time elapsed %.2fms", used);
#endif
    return data;
}

#pragma mark - Public Methods

- (void)startCaptureWithFrameHandler:(void (^)(CMSampleBufferRef _Nonnull))frameHandler {
    // Store/replace handler
    mFrameHandler = [frameHandler copy];

    if (mDisplayLink) {
        // Already running; nothing else to do
        return;
    }

    // Ensure surface exists before first tick
    [self createScreenSurfaceIfNeeded];

    // Create display link on main run loop
    void (^startBlock)(void) = ^{
        mDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLink:)];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 150000
        if (@available(iOS 15.0, *)) {
            CAFrameRateRange range;
            range.minimum = (mMinFps > 0) ? mMinFps : 0.0;
            range.maximum = (mMaxFps > 0) ? mMaxFps : 0.0;
            range.preferred = (mPreferredFps > 0) ? mPreferredFps : 0.0;
            mDisplayLink.preferredFrameRateRange = range;
        } else
#endif
        {
            // iOS 14 fallback: use preferredFramesPerSecond; choose max in the provided range
            NSInteger setFps = (mMaxFps > 0) ? mMaxFps : mPreferredFps;
            if ([mDisplayLink respondsToSelector:@selector(preferredFramesPerSecond)])
                mDisplayLink.preferredFramesPerSecond = (int)setFps; // 0 uses native/system default
        }
        [mDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    };

    if ([NSThread isMainThread]) {
        startBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), startBlock);
    }
}

- (void)endCapture {
    void (^stopBlock)(void) = ^{
        if (mDisplayLink) {
            [mDisplayLink invalidate];
            mDisplayLink = nil;
        }
        mFrameHandler = nil;

        if (mScreenSurface) {
            CFRelease(mScreenSurface);
            mScreenSurface = nil;
        }
    };

    if ([NSThread isMainThread]) {
        stopBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), stopBlock);
    }
}

// MARK: - Private

- (void)onDisplayLink:(CADisplayLink *)link {
    if (!mFrameHandler)
        return;

    // Update the screen contents into our IOSurface
    [self updateDisplay:link];

    // Wrap IOSurface in a CVPixelBuffer (zero-copy)
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *attrs = @{(NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    CVReturn cvret = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, mScreenSurface,
                                                      (__bridge CFDictionaryRef)attrs, &pixelBuffer);
    if (cvret != kCVReturnSuccess || !pixelBuffer) {
        return;
    }

    // Create format description from the pixel buffer
    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
    if (status != noErr || !formatDesc) {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    // Build timing from CADisplayLink
    int32_t timescale = 1000000000; // 1 ns
    CMSampleTimingInfo timing;
    timing.duration = CMTimeMakeWithSeconds(link.duration, timescale);
    timing.presentationTimeStamp = CMTimeMakeWithSeconds(link.timestamp, timescale);
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, formatDesc, &timing,
                                                &sampleBuffer);

    if (status == noErr && sampleBuffer) {
        mFrameHandler(sampleBuffer);
        CFRelease(sampleBuffer);
    }

    if (formatDesc)
        CFRelease(formatDesc);
    if (pixelBuffer)
        CVPixelBufferRelease(pixelBuffer);
}

@end
