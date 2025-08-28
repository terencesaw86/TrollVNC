#import "ClipboardManager.h"
#import <UIKit/UIKit.h>
#import <notify.h>

#if DEBUG
#define CMLog(fmt, ...) NSLog((@"%s:%d " fmt "\r"), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__)
#else
#define CMLog(...)
#endif

static NSString *const kPasteboardDarwinNotification = @"com.apple.pasteboard.notify.changed";

@interface ClipboardManager ()
@property(nonatomic, assign) int notifyToken;
@property(nonatomic, assign, getter=isStarted) BOOL started;
@property(nonatomic, copy) NSString *_Nullable lastSetValue;
@property(nonatomic, assign) NSInteger lastObservedChangeCount;   // last seen changeCount from UIPasteboard
@property(nonatomic, assign) NSInteger lastLocalSetBaselineCount; // changeCount observed right before a local set
@property(nonatomic, assign) NSInteger suppressNextCallbacks;     // >0: skip next onChange and one system notify once
@end

@implementation ClipboardManager

+ (instancetype)sharedManager {
    static ClipboardManager *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[self alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _notifyToken = 0;
        _started = NO;
        _lastObservedChangeCount = -1;
        _lastLocalSetBaselineCount = -1;
        _suppressNextCallbacks = 0;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    if (self.started) {
        CMLog("start called but already started");
        return;
    }
    self.started = YES;
    CMLog("Starting clipboard monitoring");

    // Register Darwin notification for pasteboard changes
    __weak __typeof(self) weakSelf = self;
    int token = 0;
    uint32_t status =
        notify_register_dispatch(kPasteboardDarwinNotification.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
            __strong __typeof(weakSelf) selfRef = weakSelf;
            if (!selfRef)
                return;
            [selfRef handlePasteboardChangeFromSystem];
        });
    if (status == NOTIFY_STATUS_OK) {
        self.notifyToken = token;
        CMLog("Registered for pasteboard notifications (token=%d)", token);
    } else {
        self.notifyToken = 0;
        CMLog("Failed to register pasteboard notifications (status=%u)", status);
    }

    // Initialize baseline change count to avoid spurious first-time callbacks
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    self.lastObservedChangeCount = pb.changeCount;
    CMLog("Initial pasteboard changeCount=%ld", (long)self.lastObservedChangeCount);
}

- (void)stop {
    if (!self.started) {
        CMLog("stop called but not started");
        return;
    }
    self.started = NO;
    CMLog("Stopping clipboard monitoring");
    if (self.notifyToken != 0) {
        notify_cancel(self.notifyToken);
        CMLog("Notification token %d canceled", self.notifyToken);
        self.notifyToken = 0;
    }
}

- (nullable NSString *)currentString {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *text = pb.string;
    if (text.length == 0)
        return nil;
    return text;
}

- (void)setString:(NSString *)text {
    if (!text)
        return;
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    // Record the baseline count before our local set; the system will bump it later in the loop.
    self.lastLocalSetBaselineCount = pb.changeCount;
    self.lastSetValue = [text copy];
    CMLog("Local setString length=%lu, baseline=%ld", (unsigned long)text.length, (long)self.lastLocalSetBaselineCount);
    pb.string = text;
    // Proactively trigger a callback so upstream can sync to remote immediately
    CMLog("Proactively dispatching local change to onChange callback");
    [self dispatchChangeIfNeededFromLocal:YES];
}

- (void)setStringFromRemote:(NSString *)text {
    if (!text)
        return;
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    // Baseline before set; and mark suppression to avoid echo
    self.lastLocalSetBaselineCount = pb.changeCount;
    self.lastSetValue = [text copy];
    self.suppressNextCallbacks = 2; // 1 for immediate local callback, 1 for following system notify
    CMLog("Remote setString length=%lu, baseline=%ld, suppression=%ld", (unsigned long)text.length, (long)self.lastLocalSetBaselineCount, (long)self.suppressNextCallbacks);
    pb.string = text;
    // Do NOT proactively callback: remote already has the content
}

#pragma mark - Internal

- (void)handlePasteboardChangeFromSystem {
    // System change notification received (triggered by external apps or by our own set)
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSInteger currentCount = pb.changeCount;
    CMLog("System pasteboard changed: changeCount=%ld (last=%ld)", (long)currentCount, (long)self.lastObservedChangeCount);

    // Ignore duplicate or out-of-order notifications
    if (self.lastObservedChangeCount == currentCount) {
        CMLog("Ignoring duplicate pasteboard notification");
        return;
    }

    // Advance baseline and then process
    self.lastObservedChangeCount = currentCount;
    CMLog("Dispatching change from system notification");
    [self dispatchChangeIfNeededFromLocal:NO];
}

- (void)dispatchChangeIfNeededFromLocal:(BOOL)local {
    NSString *current = [self currentString];

    // If suppression is active, consume one token and skip
    if (self.suppressNextCallbacks > 0) {
        self.suppressNextCallbacks -= 1;
        CMLog("Suppression active (%ld left); skipping callback", (long)self.suppressNextCallbacks);
        return;
    }

    // Avoid loop: If this matches the value we just set and this call is from the system notification, ignore it.
    // If it's a local setString call, allow the callback so the remote can be updated.
    if (!local && self.lastSetValue &&
        ((current ?: (id)NSNull.null) == (id)NSNull.null ? YES : [self.lastSetValue isEqualToString:current ?: @""])) {
        // Clear the flag once, but do not callback
        self.lastSetValue = nil;
        CMLog("Ignoring echo of locally set value from system notification");
        return;
    }

    // Optional extra guard when called from system: if we just performed a local set and
    // changeCount hasn't advanced past the baseline, skip. This protects from edge cases
    // where multiple notifications arrive in the same loop.
    if (!local && self.lastLocalSetBaselineCount >= 0) {
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        if (pb.changeCount <= self.lastLocalSetBaselineCount) {
            CMLog("Skipping due to unchanged changeCount <= baseline (%ld <= %ld)", (long)pb.changeCount, (long)self.lastLocalSetBaselineCount);
            return;
        }
        // Once we've seen a changeCount advance, clear the baseline
        self.lastLocalSetBaselineCount = -1;
    }

    // Clear lastSetValue to avoid holding references
    self.lastSetValue = nil;

    void (^cb)(NSString *_Nullable) = self.onChange;
    if (cb) {
        // Ensure callback is invoked on the main thread
        CMLog("Invoking onChange with %s string (len=%lu)", local ? "local" : "system", (unsigned long)current.length);
        if ([NSThread isMainThread]) {
            cb(current);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                cb(current);
            });
        }
    }
}

@end
