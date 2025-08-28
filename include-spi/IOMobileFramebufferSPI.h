#import <Foundation/Foundation.h>
#import <IOKit/IOReturn.h>
#import <IOSurface/IOSurfaceRef.h>

typedef IOReturn IOMobileFramebufferReturn;
typedef void *IOMobileFramebufferRef;

#ifdef __cplusplus
extern "C" {
#endif

void IOMobileFramebufferGetDisplaySize(IOMobileFramebufferRef connect, CGSize *size);
IOMobileFramebufferReturn IOMobileFramebufferGetMainDisplay(IOMobileFramebufferRef *pointer);

Boolean IOSurfaceIsInUse(IOSurfaceRef buffer);

IOMobileFramebufferReturn IOMobileFramebufferGetLayerDefaultSurface(IOMobileFramebufferRef pointer, int surface,
                                                                    IOSurfaceRef *buffer);
IOMobileFramebufferReturn IOMobileFramebufferCopyLayerDisplayedSurface(IOMobileFramebufferRef pointer, int surface,
                                                                       IOSurfaceRef *buffer);

#ifdef __cplusplus
}
#endif
