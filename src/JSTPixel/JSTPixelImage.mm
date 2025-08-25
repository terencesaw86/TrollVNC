#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import "JSTPixelImage.h"
#import "JSTPixelColor.h"
#import "JSTPixelImage+Private.h"
#import "JST_COLOR.h"
#import "JST_POS.h"

#import <Accelerate/Accelerate.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <stdlib.h>

#if TARGET_OS_IPHONE
#else
#pragma mark - NSImage (Compatibility)

@interface NSImage (Compatibility)

/**
   The underlying Core Graphics image object. This will actually use `CGImageForProposedRect` with the image size.
 */
@property(nonatomic, readonly, nullable) CGImageRef CGImage;
/**
   The scale factor of the image. This wil actually use `bestRepresentationForRect` with image size and pixel size to
   calculate the scale factor. If failed, use the default value 1.0. Should be greater than or equal to 1.0.
 */
@property(nonatomic, readonly) CGFloat scale;

// These are convenience methods to make AppKit's `NSImage` match UIKit's `UIImage` behavior. The scale factor should be
// greater than or equal to 1.0.

/**
   Returns an image object with the scale factor and orientation. The representation is created from the Core Graphics
   image object.
   @note The difference between this and `initWithCGImage:size` is that `initWithCGImage:size` will actually create a
   `NSCGImageSnapshotRep` representation and always use `backingScaleFactor` as scale factor. So we should avoid it and
   use `NSBitmapImageRep` with `initWithCGImage:` instead.
   @note The difference between this and UIKit's `UIImage` equivalent method is the way to process orientation. If the
   provided image orientation is not equal to Up orientation, this method will firstly rotate the CGImage to the correct
   orientation to work compatible with `NSImageView`. However, UIKit will not actually rotate CGImage and just store it
   as `imageOrientation` property.
   @param cgImage A Core Graphics image object
   @param scale The image scale factor
   @param orientation The orientation of the image data
   @return The image object
 */
- (nonnull instancetype)initWithCGImage:(nonnull CGImageRef)cgImage
                                  scale:(CGFloat)scale
                            orientation:(CGImagePropertyOrientation)orientation;

/**
   Returns an image object with the scale factor. The representation is created from the image data.
   @note The difference between these this and `initWithData:` is that `initWithData:` will always use
   `backingScaleFactor` as scale factor.
   @param data The image data
   @param scale The image scale factor
   @return The image object
 */
- (nullable instancetype)initWithData:(nonnull NSData *)data scale:(CGFloat)scale;

@end

NS_INLINE CGAffineTransform SDCGContextTransformFromOrientation(CGImagePropertyOrientation orientation, CGSize size) {
    // Inspiration from @libfeihu
    // We need to calculate the proper transformation to make the image upright.
    // We do it in 2 steps: Rotate if Left/Right/Down, and then flip if Mirrored.
    CGAffineTransform transform = CGAffineTransformIdentity;

    switch (orientation) {
    case kCGImagePropertyOrientationDown:
    case kCGImagePropertyOrientationDownMirrored:
        transform = CGAffineTransformTranslate(transform, size.width, size.height);
        transform = CGAffineTransformRotate(transform, M_PI);
        break;

    case kCGImagePropertyOrientationLeft:
    case kCGImagePropertyOrientationLeftMirrored:
        transform = CGAffineTransformTranslate(transform, size.width, 0);
        transform = CGAffineTransformRotate(transform, M_PI_2);
        break;

    case kCGImagePropertyOrientationRight:
    case kCGImagePropertyOrientationRightMirrored:
        transform = CGAffineTransformTranslate(transform, 0, size.height);
        transform = CGAffineTransformRotate(transform, -M_PI_2);
        break;
    case kCGImagePropertyOrientationUp:
    case kCGImagePropertyOrientationUpMirrored:
        break;
    }

    switch (orientation) {
    case kCGImagePropertyOrientationUpMirrored:
    case kCGImagePropertyOrientationDownMirrored:
        transform = CGAffineTransformTranslate(transform, size.width, 0);
        transform = CGAffineTransformScale(transform, -1, 1);
        break;

    case kCGImagePropertyOrientationLeftMirrored:
    case kCGImagePropertyOrientationRightMirrored:
        transform = CGAffineTransformTranslate(transform, size.height, 0);
        transform = CGAffineTransformScale(transform, -1, 1);
        break;
    case kCGImagePropertyOrientationUp:
    case kCGImagePropertyOrientationDown:
    case kCGImagePropertyOrientationLeft:
    case kCGImagePropertyOrientationRight:
        break;
    }

    return transform;
}

@implementation NSImage (Compatibility)

+ (BOOL)CGImageContainsAlpha:(CGImageRef)cgImage {
    if (!cgImage) {
        return NO;
    }
    CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(cgImage);
    BOOL hasAlpha = !(alphaInfo == kCGImageAlphaNone || alphaInfo == kCGImageAlphaNoneSkipFirst ||
                      alphaInfo == kCGImageAlphaNoneSkipLast);
    return hasAlpha;
}

+ (CGColorSpaceRef)colorSpaceGetDeviceRGB {
    CGColorSpaceRef screenColorSpace = NSScreen.mainScreen.colorSpace.CGColorSpace;
    if (screenColorSpace) {
        return screenColorSpace;
    }
    static CGColorSpaceRef colorSpace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {
            colorSpace = CGColorSpaceCreateDeviceRGB();
        }
    });
    return colorSpace;
}

+ (CGImageRef)CGImageCreateDecoded:(CGImageRef)cgImage orientation:(CGImagePropertyOrientation)orientation {
    if (!cgImage) {
        return NULL;
    }

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0)
        return NULL;

    size_t newWidth;
    size_t newHeight;
    switch (orientation) {
    case kCGImagePropertyOrientationLeft:
    case kCGImagePropertyOrientationLeftMirrored:
    case kCGImagePropertyOrientationRight:
    case kCGImagePropertyOrientationRightMirrored: {
        // These orientation should swap width & height
        newWidth = height;
        newHeight = width;
    } break;
    default: {
        newWidth = width;
        newHeight = height;
    } break;
    }

    BOOL hasAlpha = NO /* [self CGImageContainsAlpha:cgImage] */;
    // iOS prefer BGRA8888 (premultiplied) or BGRX8888 bitmapInfo for screen rendering, which is same as
    // `UIGraphicsBeginImageContext()` or `- [CALayer drawInContext:]` Though you can use any supported bitmapInfo (see:
    // https://developer.apple.com/library/content/documentation/GraphicsImaging/Conceptual/drawingwithquartz2d/dq_context/dq_context.html#//apple_ref/doc/uid/TP30001066-CH203-BCIBHHBB
    // ) and let Core Graphics reorder it when you call `CGContextDrawImage`

    // But since our build-in coders use this bitmapInfo, this can have a little performance benefit
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host;
    bitmapInfo |= hasAlpha ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst;
    CGContextRef context = CGBitmapContextCreate(NULL, newWidth, newHeight, 8, 0 /* auto calculated and aligned */,
                                                 [self colorSpaceGetDeviceRGB], bitmapInfo);
    if (!context) {
        return NULL;
    }

    // Apply transform
    CGAffineTransform transform = SDCGContextTransformFromOrientation(orientation, CGSizeMake(newWidth, newHeight));
    CGContextConcatCTM(context, transform);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height),
                       cgImage); // The rect is bounding box of CGImage, don't swap width & height
    CGImageRef newImageRef = CGBitmapContextCreateImage(context);
    CGContextRelease(context);

    return newImageRef;
}

- (nullable CGImageRef)CGImage {
    NSRect imageRect = NSMakeRect(0, 0, self.size.width, self.size.height);
    CGImageRef cgImage = [self CGImageForProposedRect:&imageRect context:nil hints:nil];
    return cgImage;
}

- (CGFloat)scale {
    CGFloat scale = 1;
    NSRect imageRect = NSMakeRect(0, 0, self.size.width, self.size.height);
    NSImageRep *imageRep = [self bestRepresentationForRect:imageRect context:nil hints:nil];
    CGFloat width = imageRep.size.width;
    CGFloat height = imageRep.size.height;
    NSUInteger pixelWidth = imageRep.pixelsWide;
    NSUInteger pixelHeight = imageRep.pixelsHigh;
    if (width > 0 && height > 0) {
        CGFloat widthScale = pixelWidth / width;
        CGFloat heightScale = pixelHeight / height;
        if (widthScale == heightScale && widthScale >= 1) {
            // Protect because there may be `NSImageRepMatchesDevice` (0)
            scale = widthScale;
        }
    }

    return scale;
}

- (instancetype)initWithCGImage:(nonnull CGImageRef)cgImage
                          scale:(CGFloat)scale
                    orientation:(CGImagePropertyOrientation)orientation {
    NSBitmapImageRep *imageRep;
    if (orientation != kCGImagePropertyOrientationUp) {
        // AppKit design is different from UIKit. Where CGImage based image rep does not respect to any orientation.
        // Only data based image rep which contains the EXIF metadata can automatically detect orientation. This should
        // be nonnull, until the memory is exhausted cause `CGBitmapContextCreate` failed.
        CGImageRef rotatedCGImage = [NSImage CGImageCreateDecoded:cgImage orientation:orientation];
        imageRep = [[NSBitmapImageRep alloc] initWithCGImage:rotatedCGImage];
        CGImageRelease(rotatedCGImage);
    } else {
        imageRep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
    }
    if (scale < 1) {
        scale = 1;
    }
    CGFloat pixelWidth = imageRep.pixelsWide;
    CGFloat pixelHeight = imageRep.pixelsHigh;
    NSSize size = NSMakeSize(pixelWidth / scale, pixelHeight / scale);
    self = [self initWithSize:size];
    if (self) {
        imageRep.size = size;
        [self addRepresentation:imageRep];
    }
    return self;
}

- (instancetype)initWithData:(nonnull NSData *)data scale:(CGFloat)scale {
    NSBitmapImageRep *imageRep = [[NSBitmapImageRep alloc] initWithData:data];
    if (!imageRep) {
        return nil;
    }
    if (scale < 1) {
        scale = 1;
    }
    CGFloat pixelWidth = imageRep.pixelsWide;
    CGFloat pixelHeight = imageRep.pixelsHigh;
    NSSize size = NSMakeSize(pixelWidth / scale, pixelHeight / scale);
    self = [self initWithSize:size];
    if (self) {
        imageRep.size = size;
        [self addRepresentation:imageRep];
    }
    return self;
}

@end
#endif

#pragma mark - JSTPixelImage

static JST_IMAGE *JSTCreatePixelImageWithScaledCGImage(CGImageRef cgImage, CGColorSpaceRef *cgColorSpace, int width,
                                                       int height) {
    JST_IMAGE *newPixelImage = (JST_IMAGE *)calloc(1, sizeof(JST_IMAGE));
    NSCAssert(newPixelImage, @"calloc");
    newPixelImage->width = width;
    newPixelImage->alignedWidth = width;
    newPixelImage->height = height;

    /* New pixel image is not aligned */
    JST_COLOR *pixels = (JST_COLOR *)calloc(width * height, sizeof(JST_COLOR));
    NSCAssert(pixels, @"calloc");
    newPixelImage->pixels = pixels;

    CGColorSpaceRef colorSpace = CGImageGetColorSpace(cgImage);
    if (colorSpace && CGColorSpaceGetNumberOfComponents(colorSpace) == 3) {
        *cgColorSpace = (CGColorSpaceRef)CFRetain(colorSpace);
    } else {
        *cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    }

    CGContextRef context = CGBitmapContextCreate(
        pixels, (CGFloat)width, (CGFloat)height, sizeof(JST_COLOR_COMPONENT_TYPE) * BYTE_SIZE,
        (CGFloat)width * sizeof(JST_COLOR), *cgColorSpace,
        kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst /* kCGImageAlphaNoneSkipFirst */
    );

    NSCAssert(context, @"CGBitmapContextCreate");

    CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), cgImage);
    CGContextRelease(context);
    return newPixelImage;
}

static JST_IMAGE *JSTCreatePixelImageWithCGImage(CGImageRef cgImage, CGColorSpaceRef *cgColorSpace) {
    return JSTCreatePixelImageWithScaledCGImage(cgImage, cgColorSpace, (int)CGImageGetWidth(cgImage),
                                                (int)CGImageGetHeight(cgImage));
}

static JST_IMAGE *JSTCreatePixelImageWithSize(CGSize imgSize) {
    JST_IMAGE *newPixelImage = (JST_IMAGE *)calloc(1, sizeof(JST_IMAGE));
    NSCAssert(newPixelImage, @"calloc");
    newPixelImage->width = imgSize.width;
    newPixelImage->alignedWidth = imgSize.width;
    newPixelImage->height = imgSize.height;

    /* New pixel image is not aligned */
    JST_COLOR *pixels = (JST_COLOR *)calloc(imgSize.width * imgSize.height, sizeof(JST_COLOR));
    NSCAssert(pixels, @"calloc");
    newPixelImage->pixels = pixels;

    newPixelImage->orientation = JST_ORIENTATION_HOME_ON_BOTTOM;
    newPixelImage->isDestroyed = NO;

    return newPixelImage;
}

#if TARGET_OS_IPHONE
static JST_IMAGE *JSTCreatePixelImageWithUIImage(UIImage *uiimg, CGColorSpaceRef *cgColorSpace) {
    return JSTCreatePixelImageWithCGImage(uiimg.CGImage, cgColorSpace);
}
#else
static JST_IMAGE *JSTCreatePixelImageWithNSImage(NSImage *nsimg, CGColorSpaceRef *cgColorSpace) {
    CGSize imgSize = nsimg.size;
    CGRect imgRect = CGRectMake(0, 0, imgSize.width, imgSize.height);
    return JSTCreatePixelImageWithCGImage([nsimg CGImageForProposedRect:&imgRect context:nil hints:nil], cgColorSpace);
}
#endif

static CGImageRef JSTCreateCGImageWithPixelImage(JST_IMAGE *pixelImage, CGColorSpaceRef cgColorSpace) {
    int width, height;
    switch (pixelImage->orientation) {
    case 1:
    case 2:
        height = pixelImage->width;
        width = pixelImage->height;
        break;
    default:
        width = pixelImage->width;
        height = pixelImage->height;
        break;
    }

    /* CGImage is not aligned */
    size_t pixelsBufferLength = (size_t)(width * height * sizeof(JST_COLOR));
    JST_COLOR *pixelsBuffer = (JST_COLOR *)malloc(pixelsBufferLength);
    NSCAssert(pixelsBuffer, @"malloc");

    if (JST_ORIENTATION_HOME_ON_BOTTOM == pixelImage->orientation && pixelImage->width == pixelImage->alignedWidth) {
        memcpy(pixelsBuffer, pixelImage->pixels, pixelsBufferLength);
    } else {
        uint64_t bigCountOffset = 0;
        JST_COLOR colorOfPoint;
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                JSTGetColorInPixelImage(pixelImage, x, y, &colorOfPoint);
                pixelsBuffer[bigCountOffset++].theColor = colorOfPoint.theColor;
            }
        }
    }

    CFDataRef imageData = CFDataCreateWithBytesNoCopy(kCFAllocatorMalloc, (const UInt8 *)pixelsBuffer,
                                                      pixelsBufferLength, kCFAllocatorMalloc);
    CGDataProviderRef imageDataProvider = CGDataProviderCreateWithCFData(imageData);

    CGImageRef cgImage = CGImageCreate((size_t)width, (size_t)height, sizeof(JST_COLOR_COMPONENT_TYPE) * BYTE_SIZE,
                                       sizeof(JST_COLOR_COMPONENT_TYPE) * BYTE_SIZE * JST_COLOR_COMPONENTS_PER_ELEMENT,
                                       JST_COLOR_COMPONENTS_PER_ELEMENT * width, cgColorSpace,
                                       kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst, imageDataProvider,
                                       NULL, YES, kCGRenderingIntentDefault);

    CGDataProviderRelease(imageDataProvider);
    CFRelease(imageData);

    return cgImage;
}

static JST_IMAGE *JSTCreatePixelImageWithPixelImageInRect(JST_IMAGE *pixelImage, JST_ORIENTATION orientation, int x1,
                                                          int y1, int x2, int y2) {
    int oldAlignedWidth = pixelImage->alignedWidth;
    int newWidth = x2 - x1;
    int newHeight = y2 - y1;

    JST_IMAGE *newPixelImage = (JST_IMAGE *)calloc(1, sizeof(JST_IMAGE));
    NSCAssert(newPixelImage, @"calloc");
    newPixelImage->width = newWidth;
    newPixelImage->alignedWidth = newWidth;
    newPixelImage->height = newHeight;

    /* New pixel image is not aligned */
    JST_COLOR *newPixels = (JST_COLOR *)calloc(newWidth * newHeight, sizeof(JST_COLOR));
    NSCAssert(newPixels, @"calloc");
    newPixelImage->pixels = newPixels;

    uint64_t bigCountOffset = 0;
    for (int y = y1; y < y2; ++y)
        for (int x = x1; x < x2; ++x)
            newPixels[bigCountOffset++] = pixelImage->pixels[y * oldAlignedWidth + x];

    GET_ROTATE_ROTATE3(pixelImage->orientation, orientation, newPixelImage->orientation);
    return newPixelImage;
}

@implementation JSTPixelImage

- (JSTPixelImage *)initWithSize:(CGSize)size {
    self = [super init];
    if (self) {
        _pixelImage = JSTCreatePixelImageWithSize(size);
        _colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    }
    return self;
}

- (JSTPixelImage *)initWithCGImage:(CGImageRef)cgImage {
    self = [super init];
    if (self)
        _pixelImage = JSTCreatePixelImageWithCGImage(cgImage, &_colorSpace);
    return self;
}

- (JSTPixelImage *)initWithCGImage:(CGImageRef)cgImage size:(CGSize)size {
    self = [super init];
    if (self)
        _pixelImage = JSTCreatePixelImageWithScaledCGImage(cgImage, &_colorSpace, (int)size.width, (int)size.height);
    return self;
}

- (JSTPixelImage *)initWithSystemImage:(SystemImage *)systemImage {
    self = [super init];
    if (self) {
#if TARGET_OS_IPHONE
        _pixelImage = JSTCreatePixelImageWithUIImage(systemImage, &_colorSpace);
#else
        _pixelImage = JSTCreatePixelImageWithNSImage(systemImage, &_colorSpace);
#endif
    }
    return self;
}

+ (JSTPixelImage *)imageWithSystemImage:(SystemImage *)systemImage {
    return [[JSTPixelImage alloc] initWithSystemImage:systemImage];
}

- (JSTPixelImage *)initWithInternalPointer:(JST_IMAGE *)pointer colorSpace:(CGColorSpaceRef)colorSpace {
    self = [super init];
    if (self) {
        _pixelImage = pointer;
        _colorSpace = CGColorSpaceRetain(colorSpace);
    }
    return self;
}

- (JSTPixelImage *)initWithCompatibleScreenSurface:(IOSurfaceRef)surface colorSpace:(CGColorSpaceRef)colorSpace {
    self = [super init];
    if (self) {
        _pixelImage = (JST_IMAGE *)calloc(1, sizeof(JST_IMAGE));
        NSAssert(_pixelImage, @"calloc");

        size_t width = IOSurfaceGetWidth(surface);
        size_t height = IOSurfaceGetHeight(surface);

        OSType pixelFormat = IOSurfaceGetPixelFormat(surface);
        NSAssert(pixelFormat == 0x42475241 || pixelFormat == 0x0 /* Not Specified */,
                 @"pixel format not supported 0x%x", pixelFormat);

        size_t bytesPerElement = IOSurfaceGetBytesPerElement(surface);
        NSAssert(bytesPerElement == sizeof(JST_COLOR), @"bpc not supported %ld", bytesPerElement);

        size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
        NSAssert(bytesPerRow == width * sizeof(JST_COLOR) ||
                     (bytesPerRow > width * sizeof(JST_COLOR) && bytesPerRow % 32 == 0),
                 @"bpr not aligned %ld", bytesPerRow);

        /* Pixel image from IOSurface is aligned */
        size_t alignedWidth = bytesPerRow / sizeof(JST_COLOR);
        void *pixels = IOSurfaceGetBaseAddress(surface);

        _pixelImage->width = (int)width;
        _pixelImage->alignedWidth = (int)alignedWidth;
        _pixelImage->height = (int)height;
        _pixelImage->pixels = (JST_COLOR *)pixels;
        _pixelImage->isDestroyed = YES;

        _colorSpace = CGColorSpaceRetain(colorSpace);
    }
    return self;
}

- (CGImageRef)_createCGImage {
    return JSTCreateCGImageWithPixelImage(_pixelImage, _colorSpace);
}

- (SystemImage *)toSystemImage {
    CGImageRef cgimg = JSTCreateCGImageWithPixelImage(_pixelImage, _colorSpace);
#if TARGET_OS_IPHONE
    UIImage *img0 = [UIImage imageWithCGImage:cgimg];
#else
    NSImage *img0 = [[NSImage alloc] initWithCGImage:cgimg scale:1.0 orientation:kCGImagePropertyOrientationUp];
#endif
    CGImageRelease(cgimg);
    return img0;
}

#pragma mark - Getters

- (JST_IMAGE *)internalBuffer {
    return _pixelImage;
}

- (CGSize)orientedSize {
    int width = 0, height = 0;
    switch (_pixelImage->orientation) {
    case 1:
    case 2:
        height = _pixelImage->width;
        width = _pixelImage->height;
        break;
    default:
        width = _pixelImage->width;
        height = _pixelImage->height;
        break;
    }
    return CGSizeMake(width, height);
}

- (CGRect)orientedBounds {
    CGSize orientSize = [self orientedSize];
    return CGRectMake(0, 0, orientSize.width, orientSize.height);
}

- (JST_ORIENTATION)orientation {
    return _pixelImage->orientation;
}

- (void)setOrientation:(JST_ORIENTATION)orientation {
    _pixelImage->orientation = orientation;
}

- (NSString *)colorSpaceName {
    return CFBridgingRelease(CGColorSpaceCopyName(_colorSpace));
}

#pragma mark - Coordinate

- (BOOL)containsOrientedPoint:(CGPoint)orientedPoint {
    return CGRectContainsPoint([self orientedBounds], orientedPoint);
}

- (BOOL)intersectsOrientedRect:(CGRect)orientedRect {
    return CGRectIntersectsRect([self orientedBounds], orientedRect);
}

#pragma mark - Transformation

- (vImage_Error)crop:(CGRect)rect {
    CGRect restrictedRect = CGRectIntersection([self orientedBounds], rect);
    NSAssert(!CGRectIsNull(restrictedRect), @"invalid region");

    vImagePixelCount cHeight = static_cast<vImagePixelCount>(CGRectGetHeight(restrictedRect));
    vImagePixelCount cWidth = static_cast<vImagePixelCount>(CGRectGetWidth(restrictedRect));

    vImage_Error error = kvImageNoError;
    vImage_Buffer dstBuffer;
    error = vImageBuffer_Init(&dstBuffer, cHeight, cWidth, sizeof(JST_COLOR) * BYTE_SIZE, kvImageNoFlags);
    if (error != kvImageNoError)
        return error;

    /* Image Normalization */
    [self normalize];

    JST_COLOR *beginPtr = _pixelImage->pixels;

    vImage_Buffer srcBuffer{
        .data = beginPtr,
        .width = static_cast<vImagePixelCount>(_pixelImage->width),
        .height = static_cast<vImagePixelCount>(_pixelImage->height),
        .rowBytes = static_cast<size_t>(_pixelImage->alignedWidth * sizeof(JST_COLOR)),
    };

    vImagePixelCount cMinX = static_cast<vImagePixelCount>(CGRectGetMinX(restrictedRect));
    vImagePixelCount cMinY = static_cast<vImagePixelCount>(CGRectGetMinY(restrictedRect));

    vImage_Buffer croppedBuffer{
        .data = &beginPtr[cMinY * srcBuffer.width + cMinX],
        .width = dstBuffer.width,
        .height = dstBuffer.height,
        .rowBytes = srcBuffer.rowBytes,
    };

    error = vImageCopyBuffer(&croppedBuffer, &dstBuffer, sizeof(JST_COLOR), kvImageNoFlags);
    if (error != kvImageNoError) {
        free(dstBuffer.data);
        return error;
    }

    free(srcBuffer.data);
    _pixelImage->width = static_cast<int>(dstBuffer.width);
    _pixelImage->alignedWidth = static_cast<int>(dstBuffer.rowBytes / sizeof(JST_COLOR));
    _pixelImage->height = static_cast<int>(dstBuffer.height);
    _pixelImage->orientation = JST_ORIENTATION_HOME_ON_BOTTOM;
    _pixelImage->pixels = (JST_COLOR *)dstBuffer.data;
    _pixelImage->isDestroyed = NO;

    return error;
}

- (vImage_Error)resize:(CGSize)size {
    vImagePixelCount cHeight = static_cast<vImagePixelCount>(size.height);
    vImagePixelCount cWidth = static_cast<vImagePixelCount>(size.width);

    vImage_Error error = kvImageNoError;
    vImage_Buffer dstBuffer;
    error = vImageBuffer_Init(&dstBuffer, cHeight, cWidth, sizeof(JST_COLOR) * BYTE_SIZE, kvImageNoFlags);
    if (error != kvImageNoError)
        return error;

    /* Image Normalization */
    [self normalize];

    vImage_Buffer srcBuffer{
        .data = _pixelImage->pixels,
        .width = static_cast<vImagePixelCount>(_pixelImage->width),
        .height = static_cast<vImagePixelCount>(_pixelImage->height),
        .rowBytes = static_cast<size_t>(_pixelImage->alignedWidth * sizeof(JST_COLOR)),
    };

    error = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, NULL, kvImageNoFlags);
    if (error != kvImageNoError) {
        free(dstBuffer.data);
        return error;
    }

    free(srcBuffer.data);
    _pixelImage->width = static_cast<int>(dstBuffer.width);
    _pixelImage->alignedWidth = static_cast<int>(dstBuffer.rowBytes / sizeof(JST_COLOR));
    _pixelImage->height = static_cast<int>(dstBuffer.height);
    _pixelImage->orientation = JST_ORIENTATION_HOME_ON_BOTTOM;
    _pixelImage->pixels = (JST_COLOR *)dstBuffer.data;
    _pixelImage->isDestroyed = NO;

    return error;
}

- (ssize_t)reflect:(JSTPixelImageReflection)direction {
    /* No need to do normalization. */
    vImage_Error error = kvImageNoError;

    if (direction < 0) {
        JST_ORIENTATION orient = _pixelImage->orientation;
        GET_ROTATE_ROTATE3(orient, JST_ORIENTATION_HOME_ON_TOP, _pixelImage->orientation);
        return error;
    }

    vImage_Buffer srcBuffer{
        .data = _pixelImage->pixels,
        .width = static_cast<vImagePixelCount>(_pixelImage->width),
        .height = static_cast<vImagePixelCount>(_pixelImage->height),
        .rowBytes = static_cast<size_t>(_pixelImage->alignedWidth * sizeof(JST_COLOR)),
    };

    vImage_Buffer tmpBuffer;
    error =
        vImageBuffer_Init(&tmpBuffer, srcBuffer.height, srcBuffer.width, sizeof(JST_COLOR) * BYTE_SIZE, kvImageNoFlags);
    if (error != kvImageNoError)
        return error;

    /* But we need to adjust the direction. */
    BOOL isPortait = (_pixelImage->orientation == JST_ORIENTATION_HOME_ON_BOTTOM ||
                      _pixelImage->orientation == JST_ORIENTATION_HOME_ON_TOP);
    if (isPortait == (direction > 0))
        error = vImageHorizontalReflect_ARGB8888(&srcBuffer, &tmpBuffer, kvImageNoFlags);
    else
        error = vImageVerticalReflect_ARGB8888(&srcBuffer, &tmpBuffer, kvImageNoFlags);

    if (error != kvImageNoError) {
        free(tmpBuffer.data);
        return error;
    }

    vImageCopyBuffer(&tmpBuffer, &srcBuffer, sizeof(JST_COLOR), kvImageNoFlags);
    free(tmpBuffer.data);

    return error;
}

#pragma mark - Transformation (Copying)

- (JSTPixelImage *)croppedImageWithRect:(CGRect)rect {
    CGRect restrictedRect = CGRectIntersection([self orientedBounds], rect);
    NSAssert(!CGRectIsNull(restrictedRect), @"invalid region");

    int cMinX = (int)CGRectGetMinX(restrictedRect), cMinY = (int)CGRectGetMinY(restrictedRect),
        cMaxX = (int)CGRectGetMaxX(restrictedRect), cMaxY = (int)CGRectGetMaxY(restrictedRect);

    SHIFT_RECT_BY_ORIEN(cMinX, cMinY, cMaxX, cMaxY, _pixelImage->width, _pixelImage->height, _pixelImage->orientation);

    cMaxY = (cMaxY > _pixelImage->height) ? _pixelImage->height : cMaxY;
    cMaxX = (cMaxX > _pixelImage->width) ? _pixelImage->width : cMaxX;

    JST_IMAGE *newImage = JSTCreatePixelImageWithPixelImageInRect(_pixelImage, JST_ORIENTATION_HOME_ON_BOTTOM, cMinX,
                                                                  cMinY, cMaxX, cMaxY);

    return [[JSTPixelImage alloc] initWithInternalPointer:newImage colorSpace:_colorSpace];
}

- (JSTPixelImage *)resizedImageWithSize:(CGSize)size {
    JSTPixelImage *newImage = [self copy];
    vImage_Error error = [newImage resize:size];
    NSAssert(error == kvImageNoError, @"error occurred: %zd", error);
    return newImage;
}

- (JSTPixelImage *)reflectedImageWithDirection:(JSTPixelImageReflection)direction {
    JSTPixelImage *newImage = [self copy];
    vImage_Error error = [newImage reflect:direction];
    NSAssert(error == kvImageNoError, @"error occurred: %zd", error);
    return newImage;
}

#pragma mark - Transformation (Normalized)

- (JSTPixelImage *)restrictedImageWithRect:(CGRect)rect {
    NSAssert(_pixelImage->orientation == JST_ORIENTATION_HOME_ON_BOTTOM, @"not a normalized image");

    CGRect restrictedRect = CGRectIntersection([self orientedBounds], rect);
    NSAssert(!CGRectIsNull(restrictedRect), @"invalid region");

    int cHeight = static_cast<int>(CGRectGetHeight(restrictedRect)),
        cWidth = static_cast<int>(CGRectGetWidth(restrictedRect)),
        cMinX = static_cast<int>(CGRectGetMinX(restrictedRect)),
        cMinY = static_cast<int>(CGRectGetMinY(restrictedRect));

    int alignedWidth = _pixelImage->alignedWidth;

    JST_IMAGE *newImage = (JST_IMAGE *)calloc(1, sizeof(JST_IMAGE));
    NSAssert(newImage, @"calloc");
    newImage->width = static_cast<int>(cWidth);
    newImage->alignedWidth = alignedWidth;
    newImage->height = static_cast<int>(cHeight);
    newImage->orientation = JST_ORIENTATION_HOME_ON_BOTTOM;
    newImage->pixels = &_pixelImage->pixels[cMinY * alignedWidth + cMinX];
    newImage->isDestroyed = YES;

    return [[JSTPixelImage alloc] initWithInternalPointer:newImage colorSpace:_colorSpace];
}

#pragma mark - Pixel Getters

- (NSString *)getColorHexOfPoint:(CGPoint)point {
    JST_COLOR colorOfPoint;
    JSTGetColorInPixelImageSafe(_pixelImage, (int)point.x, (int)point.y, &colorOfPoint);
    return [[JSTPixelColor colorWithRed:colorOfPoint.red
                                  green:colorOfPoint.green
                                   blue:colorOfPoint.blue
                                  alpha:colorOfPoint.alpha] hexString];
}

- (JSTPixelColor *)getJSTColorOfPoint:(CGPoint)point {
    JST_COLOR colorOfPoint;
    JSTGetColorInPixelImageSafe(_pixelImage, (int)point.x, (int)point.y, &colorOfPoint);
    return [JSTPixelColor colorWithRed:colorOfPoint.red
                                 green:colorOfPoint.green
                                  blue:colorOfPoint.blue
                                 alpha:colorOfPoint.alpha];
}

- (JST_COLOR_TYPE)getColorOfPoint:(CGPoint)point {
    JST_COLOR colorOfPoint;
    JSTGetColorInPixelImageSafe(_pixelImage, (int)point.x, (int)point.y, &colorOfPoint);
    return colorOfPoint.theColor;
}

#pragma mark - Pixel Setters

- (void)setColor:(JST_COLOR_TYPE)color ofPoint:(CGPoint)point {
    JST_COLOR colorOfPoint;
    colorOfPoint.theColor = color;
    JSTSetColorInPixelImageSafe(_pixelImage, (int)point.x, (int)point.y, &colorOfPoint);
}

- (void)setJSTColor:(JSTPixelColor *)color ofPoint:(CGPoint)point {
    JST_COLOR colorOfPoint;
    colorOfPoint.red = color.red;
    colorOfPoint.green = color.green;
    colorOfPoint.blue = color.blue;
    colorOfPoint.alpha = 0xff;
    JSTSetColorInPixelImageSafe(_pixelImage, (int)point.x, (int)point.y, &colorOfPoint);
}

#pragma mark - Serialization

- (NSData *)dataRepresentation {
    size_t bufferSize = _pixelImage->alignedWidth * _pixelImage->height * sizeof(JST_COLOR);
    size_t structSize = sizeof(JST_IMAGE) + bufferSize;

    NSMutableData *data = [[NSMutableData alloc] initWithCapacity:structSize];

    JST_IMAGE bufferImage;
    memcpy(&bufferImage, _pixelImage, sizeof(JST_IMAGE));
    bufferImage.pixels = NULL;
    bufferImage.isDestroyed = NO;
    [data appendBytes:&bufferImage length:sizeof(JST_IMAGE)];

    JST_COLOR *pixels = _pixelImage->pixels;
    [data appendBytes:pixels length:bufferSize];

    return data;
}

- (NSData *)pngRepresentation {
    CGImageRef cgimg = JSTCreateCGImageWithPixelImage(_pixelImage, _colorSpace);
#if TARGET_OS_IPHONE
    NSData *data = UIImagePNGRepresentation([UIImage imageWithCGImage:cgimg]);
#else
    NSBitmapImageRep *newRep = [[NSBitmapImageRep alloc] initWithCGImage:cgimg];
    [newRep setSize:CGSizeMake(CGImageGetWidth(cgimg), CGImageGetHeight(cgimg))];
    NSData *data = [newRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
#endif
    CGImageRelease(cgimg);
    return data;
}

#if TARGET_OS_IPHONE
- (NSData *)jpegRepresentationWithCompressionQuality:(CGFloat)compressionQuality {
    CGImageRef cgimg = JSTCreateCGImageWithPixelImage(_pixelImage, _colorSpace);
    NSData *data = UIImageJPEGRepresentation([UIImage imageWithCGImage:cgimg], compressionQuality);
    CGImageRelease(cgimg);
    return data;
}
#else
- (NSData *)tiffRepresentation {
    CGImageRef cgimg = JSTCreateCGImageWithPixelImage(_pixelImage, _colorSpace);
    NSBitmapImageRep *newRep = [[NSBitmapImageRep alloc] initWithCGImage:cgimg];
    [newRep setSize:CGSizeMake(CGImageGetWidth(cgimg), CGImageGetHeight(cgimg))];
    NSData *data = [newRep representationUsingType:NSBitmapImageFileTypeTIFF properties:@{}];
    CGImageRelease(cgimg);
    return data;
}
#endif

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    JST_IMAGE *newImage = (JST_IMAGE *)calloc(1, sizeof(JST_IMAGE));
    NSAssert(newImage, @"calloc");
    memcpy(newImage, _pixelImage, sizeof(JST_IMAGE));

    /* Copied pixel image has the same alignment with the original ones */
    size_t pixelSize = newImage->alignedWidth * newImage->height * sizeof(JST_COLOR);
    JST_COLOR *pixels = (JST_COLOR *)malloc(pixelSize);
    NSAssert(pixels, @"malloc");
    memcpy(pixels, newImage->pixels, pixelSize);

    newImage->pixels = pixels;
    newImage->isDestroyed = NO;

    return [[JSTPixelImage alloc] initWithInternalPointer:newImage colorSpace:_colorSpace];
}

#pragma mark - Normalization

- (BOOL)isNormalized {
    return (JST_ORIENTATION_HOME_ON_BOTTOM == _pixelImage->orientation &&
            _pixelImage->width == _pixelImage->alignedWidth);
}

- (void)normalize {
    if ([self isNormalized])
        return;

    /* copy normalized buffer image */
    JST_IMAGE *newImage = NULL;
    [self copyNormalizedBuffer:&newImage];

    /* release previous buffer image */
    JSTFreePixelImage(_pixelImage);

    /* replace with new buffer image */
    _pixelImage = newImage;
}

- (void)copyNormalizedBuffer:(JST_IMAGE *_Nonnull *)buffer {
    int width, height;
    switch (_pixelImage->orientation) {
    case JST_ORIENTATION_HOME_ON_LEFT:
    case JST_ORIENTATION_HOME_ON_RIGHT:
        height = _pixelImage->width;
        width = _pixelImage->height;
        break;
    default:
        width = _pixelImage->width;
        height = _pixelImage->height;
        break;
    }

    /* remove extra alignment */
    JST_COLOR *pixelsBuffer = (JST_COLOR *)calloc(width * height, sizeof(JST_COLOR));
    NSAssert(pixelsBuffer, @"calloc");

    uint64_t bigCountOffset = 0;
    JST_COLOR colorOfPoint;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            JSTGetColorInPixelImage(_pixelImage, x, y, &colorOfPoint);
            pixelsBuffer[bigCountOffset++].theColor = colorOfPoint.theColor;
        }
    }

    (*buffer) = (JST_IMAGE *)calloc(1, sizeof(JST_IMAGE));
    NSAssert(*buffer, @"calloc");
    (*buffer)->width = width;
    (*buffer)->alignedWidth = width;
    (*buffer)->height = height;
    (*buffer)->orientation = JST_ORIENTATION_HOME_ON_BOTTOM;
    (*buffer)->pixels = pixelsBuffer;
    (*buffer)->isDestroyed = NO;
}

- (JSTPixelImage *)normalizedImage {
    JSTPixelImage *newImage = [self copy];
    [newImage normalize];
    return newImage;
}

#pragma mark -

- (void)dealloc {
    JSTFreePixelImage(_pixelImage);
    CGColorSpaceRelease(_colorSpace);
}

@end
