#import <Foundation/Foundation.h>

#import "STHIDEventGenerator.h"
#import "ScreenCapturer.h"

#if DEBUG
#define TVLog(fmt, ...) NSLog((@"%s:%d " fmt "\r"), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__)
#else
#define TVLog(...)
#endif

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        ScreenCapturer *capturer = [ScreenCapturer sharedCapturer];
        [capturer startCaptureWithFrameHandler:^(CMSampleBufferRef _Nonnull sampleBuffer) {
            TVLog(@"captured frame: %@", sampleBuffer);
        }];

        STHIDEventGenerator *eventGenerator = [STHIDEventGenerator sharedGenerator];
        [eventGenerator shakeIt];
    }

    CFRunLoopRun();
    return 0;
}
