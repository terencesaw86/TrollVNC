#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import "ScreenCapturer.h"
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

#ifdef __cplusplus
extern "C" {
#endif

UIImage *_UICreateScreenUIImage(void);
CGImageRef UICreateCGImageFromIOSurface(IOSurfaceRef ioSurface);
void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y);

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
}

+ (instancetype)sharedCapturer {
    static ScreenCapturer *_inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _inst = [[self alloc] init];
    });
    return _inst;
}

+ (NSDictionary *)sharedRenderProperties {
    static NSDictionary *_renderProperties = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {

            CGRect bounds = [[UIScreen mainScreen] bounds];
            CGFloat scale = [[UIScreen mainScreen] scale];
            CGRect screenRect = CGRectMake(0, 0, round(bounds.size.width * scale), round(bounds.size.height * scale));

            // Setup the width and height of the framebuffer for the device
            int width, height;
            if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
                // iPhone frame buffer is Portrait
                width = screenRect.size.width;
                height = screenRect.size.height;
            } else {
                // iPad frame buffer is Landscape
                width = screenRect.size.height;
                height = screenRect.size.width;
            }

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
        if (mMaxFps > 0) mPreferredFps = mMaxFps;
        else if (mMinFps > 0) mPreferredFps = mMinFps;
        else mPreferredFps = 0;
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
        if ([NSThread isMainThread]) applyBlock();
        else dispatch_async(dispatch_get_main_queue(), applyBlock);
    }
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

- (BOOL)writeScreenUIImagePNGDataToFile:(NSString *)path {
    return [[self getScreenUIImagePNGData] writeToFile:path atomically:YES];
}

#pragma mark - Rendering

- (void)renderDisplayToScreenSurface:(IOSurfaceRef)dstSurface {
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
}

- (void)updateDisplay {
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
    double nowMs = (double)endAt / NSEC_PER_MSEC;
    if (nowMs - s_lastLogAtMs >= 5000.0) { // log at most once every 5 seconds
        double used = (double)(endAt - beginAt) / NSEC_PER_MSEC;
        SCLog(@"time elapsed %.2fms, %zu bytes memory used", used, [ScreenCapturer __getMemoryUsedInBytes]);
        s_lastLogAtMs = nowMs;
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
    [self updateDisplay];

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
