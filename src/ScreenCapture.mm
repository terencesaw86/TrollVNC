#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import "ScreenCapture.h"
#import <UIKit/UIDevice.h>
#import <UIKit/UIGeometry.h>
#import <UIKit/UIImage.h>
#import <UIKit/UIScreen.h>
#import <mach/mach.h>

#import "JSTPixel/JSTPixelColor.h"
#import "JSTPixel/JSTPixelImage+Private.h"
#import "JSTPixel/JSTPixelImage.h"

#pragma mark -

OBJC_EXTERN UIImage *_UICreateScreenUIImage(void);
OBJC_EXTERN CGImageRef UICreateCGImageFromIOSurface(IOSurfaceRef ioSurface);
OBJC_EXTERN void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y);

#pragma mark -

@implementation ScreenCapture {
    IOSurfaceRef mScreenSurface;
}

@synthesize underlyingPixelImage = _underlyingPixelImage;

+ (instancetype)sharedCapture {
    static ScreenCapture *_inst = nil;
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
            NSLog(@"render properties %@", _renderProperties);
#endif
        }
    });

    return _renderProperties;
}

- (void)createScreenSurfaceIfNeeded {
    if (!mScreenSurface) {
        NSDictionary *properties = [ScreenCapture sharedRenderProperties];
        mScreenSurface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    }
}

- (JSTPixelImage *)underlyingPixelImage {
    if (!_underlyingPixelImage) {
        [self createScreenSurfaceIfNeeded];

        NSDictionary *properties = [ScreenCapture sharedRenderProperties];
        CGColorSpaceRef colorSpace =
            CGColorSpaceCreateWithName((__bridge CFStringRef)properties[(__bridge NSString *)kIOSurfaceColorSpace]);
        _underlyingPixelImage = [[JSTPixelImage alloc] initWithCompatibleScreenSurface:mScreenSurface
                                                                            colorSpace:colorSpace];
        CGColorSpaceRelease(colorSpace);
    }
    return _underlyingPixelImage;
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
    NSLog(@"render properties %@", properties);
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
    static IOSurfaceAcceleratorRef _sharedAccelerator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {
            srcSurface = IOSurfaceCreate((__bridge CFDictionaryRef)[ScreenCapture sharedRenderProperties]);
            IOSurfaceAcceleratorCreate(kCFAllocatorDefault, nil, &_sharedAccelerator);

            CFRunLoopSourceRef runLoopSource = IOSurfaceAcceleratorGetRunLoopSource(_sharedAccelerator);
            CFRunLoopAddSource(runLoop, runLoopSource, kCFRunLoopDefaultMode);
        }
    });

    /// Fast ~20ms, sRGB, while the image is GOOD. Recommended.
    CARenderServerRenderDisplay(0, CFSTR("LCD"), srcSurface, 0, 0);
    IOSurfaceAcceleratorTransformSurface(_sharedAccelerator, srcSurface, dstSurface, NULL, NULL, NULL, NULL, NULL);
}

- (void)renderDisplayToSharedScreenSurface {
#if DEBUG
    __uint64_t beginAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif

    [self createScreenSurfaceIfNeeded];

    // Lock the surface
    IOSurfaceLock(mScreenSurface, 0, &_seed);

    [self renderDisplayToScreenSurface:mScreenSurface];

    // Unlock the surface
    IOSurfaceUnlock(mScreenSurface, 0, &_seed);

#if DEBUG
    __uint64_t endAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double used = (double)(endAt - beginAt) / NSEC_PER_MSEC;
    NSLog(@"time elapsed %.2fms, %zu bytes memory used", used, [ScreenCapture __getMemoryUsedInBytes]);
#endif
}

- (IOSurfaceRef)copyScreenSurface {
#if DEBUG
    __uint64_t beginAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif

    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)[ScreenCapture sharedRenderProperties]);

    // Lock the surface
    IOSurfaceLock(surface, 0, &_seed);

    [self renderDisplayToScreenSurface:surface];

    // Unlock the surface
    IOSurfaceUnlock(surface, 0, &_seed);

#if DEBUG
    __uint64_t endAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double used = (double)(endAt - beginAt) / NSEC_PER_MSEC;
    NSLog(@"time elapsed %.2fms", used);
#endif

    return surface;
}

- (CGImageRef)copyScreenCGImage {
#if DEBUG
    __uint64_t beginAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif

    NSDictionary *screenProperties = [ScreenCapture sharedRenderProperties];

    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)screenProperties);

    // Lock the surface
    IOSurfaceLock(surface, 0, &_seed);

    [self renderDisplayToScreenSurface:surface];

    // Make a raw memory copy of the surface
    void *baseAddr = IOSurfaceGetBaseAddress(surface);
    size_t allocSize = IOSurfaceGetAllocSize(surface);

    CFDataRef rawData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)baseAddr, allocSize);
    CGDataProviderRef dataProvider = CGDataProviderCreateWithCFData(rawData);

    int width = [screenProperties[(__bridge NSString *)kIOSurfaceWidth] intValue];
    int height = [screenProperties[(__bridge NSString *)kIOSurfaceHeight] intValue];
    int bytesPerRow = [screenProperties[(__bridge NSString *)kIOSurfaceBytesPerRow] intValue];
    int bytesPerComponent = sizeof(uint8_t);
    int bytesPerElement = [screenProperties[(__bridge NSString *)kIOSurfaceBytesPerElement] intValue];

    CGColorSpaceRef colorSpace =
        CGColorSpaceCreateWithName((__bridge CFStringRef)screenProperties[(__bridge NSString *)kIOSurfaceColorSpace]);

    CGImageRef cgImage = CGImageCreate(width, height, bytesPerComponent * BYTE_SIZE, bytesPerElement * BYTE_SIZE,
                                       bytesPerRow /* already aligned */, colorSpace,
                                       kCGBitmapByteOrder32Host | kCGImageAlphaNoneSkipFirst, dataProvider, NULL, NO,
                                       kCGRenderingIntentDefault);

    CGDataProviderRelease(dataProvider);
    CGColorSpaceRelease(colorSpace);
    CFRelease(rawData);

    // Unlock and release the surface
    IOSurfaceUnlock(surface, 0, &_seed);
    CFRelease(surface);

#if DEBUG
    __uint64_t endAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double used = (double)(endAt - beginAt) / NSEC_PER_MSEC;
    NSLog(@"time elapsed %.2fms", used);
#endif
    return cgImage;
}

- (UIImage *)getScreenUIImage {
#if DEBUG
    __uint64_t beginAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif

    UIImage *uiImage = _UICreateScreenUIImage();

#if DEBUG
    __uint64_t endAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double used = (double)(endAt - beginAt) / NSEC_PER_MSEC;
    NSLog(@"time elapsed %.2fms", used);
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
    NSLog(@"time elapsed %.2fms", used);
#endif
    return data;
}

#pragma mark - Transfer

- (NSData *)getScreenUIImageRAWDataNoCopy {
#if DEBUG
    __uint64_t beginAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif

    [self createScreenSurfaceIfNeeded];
    [self renderDisplayToSharedScreenSurface];

    void *baseAddr = IOSurfaceGetBaseAddress(mScreenSurface);
    size_t allocSize = IOSurfaceGetAllocSize(mScreenSurface);
    NSData *data = nil;

    if (baseAddr && allocSize > 0) {
        data = [NSData dataWithBytesNoCopy:baseAddr length:allocSize freeWhenDone:NO];
    } else {
        data = [NSData data];
    }

#if DEBUG
    __uint64_t endAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double used = (double)(endAt - beginAt) / NSEC_PER_MSEC;
    NSLog(@"time elapsed %.2fms, %zu bytes memory used", used, [ScreenCapture __getMemoryUsedInBytes]);
#endif

    return data;
}

#pragma mark - Remote Client

- (void)transferDisplayToSharedScreenSurface {
    [self createScreenSurfaceIfNeeded];
    [self transferDisplayToScreenSurface:mScreenSurface];
}

- (void)transferDisplayToScreenSurface:(IOSurfaceRef)surface {
#if DEBUG
    __uint64_t beginAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif

    // Lock the surface
    IOSurfaceLock(surface, 0, &_seed);

    NSData *replyData = [self getScreenUIImageRAWDataNoCopy];
    void *baseAddr = IOSurfaceGetBaseAddress(surface);
    size_t allocSize = IOSurfaceGetAllocSize(surface);

    if ([replyData isKindOfClass:[NSData class]]) {
        memcpy(baseAddr, replyData.bytes, MIN(replyData.length, allocSize));
    } else {
        bzero(baseAddr, allocSize);
    }

    // Unlock the surface
    IOSurfaceUnlock(surface, 0, &_seed);

#if DEBUG
    __uint64_t endAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double used = (double)(endAt - beginAt) / NSEC_PER_MSEC;
    NSLog(@"time elapsed %.2fms, %zu bytes memory used", used, [ScreenCapture __getMemoryUsedInBytes]);
#endif
}

@end
