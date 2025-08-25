#import <TargetConditionals.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>

#define SystemImage UIImage
#else
#import <AppKit/AppKit.h>

#define SystemImage NSImage
#endif

#import "JST_IMAGE.h"


NS_ASSUME_NONNULL_BEGIN

typedef enum : NSInteger {
    JSTPixelImageReflectionAxisBoth = -1,
    JSTPixelImageReflectionAxisX = 0,
    JSTPixelImageReflectionAxisY = 1,
} JSTPixelImageReflection;

@class JSTPixelColor;

OBJC_VISIBLE
@interface JSTPixelImage : NSObject <NSCopying> {
    JST_IMAGE *_pixelImage;
}

/* Initializers */
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (JSTPixelImage *)initWithSize:(CGSize)size;
- (JSTPixelImage *)initWithCGImage:(CGImageRef)cgImage;
- (JSTPixelImage *)initWithCGImage:(CGImageRef)cgImage size:(CGSize)size;
- (JSTPixelImage *)initWithSystemImage:(SystemImage *)systemImage;
+ (JSTPixelImage *)imageWithSystemImage:(SystemImage *)systemImage;
- (JSTPixelImage *)initWithInternalPointer:(JST_IMAGE *)pointer colorSpace:(CGColorSpaceRef)colorSpace;
- (SystemImage *)toSystemImage;

@property (nonatomic, assign, readonly) JST_IMAGE *internalBuffer;
@property (nonatomic, assign, readonly) CGColorSpaceRef colorSpace;
@property (nonatomic, strong, readonly) NSString *colorSpaceName;
@property (nonatomic, assign, readonly) CGSize orientedSize;
@property (nonatomic, assign, readonly) CGRect orientedBounds;
@property (nonatomic, assign, readwrite) JST_ORIENTATION orientation;

/* Coordinate */
- (BOOL)containsOrientedPoint:(CGPoint)orientedPoint;
- (BOOL)intersectsOrientedRect:(CGRect)orientedRect;

/* Pixel Getters */
- (NSString *)getColorHexOfPoint:(CGPoint)point;
- (JST_COLOR_TYPE)getColorOfPoint:(CGPoint)point;
- (JSTPixelColor *)getJSTColorOfPoint:(CGPoint)point;

/* Setters */
- (void)setColor:(JST_COLOR_TYPE)color ofPoint:(CGPoint)point;
- (void)setJSTColor:(JSTPixelColor *)color ofPoint:(CGPoint)point;

/* Transformation */
- (void)normalize;
- (BOOL)isNormalized;
- (ssize_t)crop:(CGRect)rect;
- (ssize_t)resize:(CGSize)size;
- (ssize_t)reflect:(JSTPixelImageReflection)direction;
- (void)copyNormalizedBuffer:(JST_IMAGE *_Nonnull *_Nonnull)buffer;

/* Transformation (Copying) */
- (JSTPixelImage *)normalizedImage;
- (JSTPixelImage *)croppedImageWithRect:(CGRect)rect;
- (JSTPixelImage *)resizedImageWithSize:(CGSize)size;
- (JSTPixelImage *)reflectedImageWithDirection:(JSTPixelImageReflection)direction;

/* Transformation (ONLY Normalized) */
- (JSTPixelImage *)restrictedImageWithRect:(CGRect)rect;

/* Serialization */
- (NSData *)dataRepresentation;
- (NSData *)pngRepresentation;
#if TARGET_OS_IPHONE
- (NSData *)jpegRepresentationWithCompressionQuality:(CGFloat)compressionQuality;
#else
- (NSData *)tiffRepresentation;
#endif

@end

NS_ASSUME_NONNULL_END

