#ifndef ScreenCapture_h
#define ScreenCapture_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScreenCapture : NSObject

+ (instancetype)sharedCapture;
+ (NSDictionary *)sharedRenderProperties;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

- (void)updateDisplay;

@end

NS_ASSUME_NONNULL_END

#endif /* ScreenCapture_h */
