#ifndef ScreenCapture_h
#define ScreenCapture_h

#import <CoreGraphics/CGGeometry.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class JSTPixelColor;
@class JSTPixelImage;

OBJC_VISIBLE
@interface ScreenCapture : NSObject

/**
 * This is the underlying pixel image with the size of unjailed reference bounds in pixels.
 * Client may update this image by calling method -updateDisplay.
 */
@property(nonatomic, strong, readonly) JSTPixelImage *underlyingPixelImage;
@property(nonatomic, assign, readonly) uint32_t seed;

+ (instancetype)sharedCapture;
+ (NSDictionary *)sharedRenderProperties;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

- (void)renderDisplayToSharedScreenSurface;

@end

#endif /* ScreenCapture_h */

NS_ASSUME_NONNULL_END
