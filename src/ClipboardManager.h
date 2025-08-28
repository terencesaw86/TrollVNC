#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Lightweight clipboard manager that only supports UTF-8 text.
/// Wraps UIPasteboard and listens for the Darwin notification: com.apple.pasteboard.notify.changed.
/// Exposes an onChange callback invoked on the main thread.
@interface ClipboardManager : NSObject

/// Global singleton instance
+ (instancetype)sharedManager;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/// Start listening for clipboard changes (idempotent)
- (void)start;

/// Stop listening for clipboard changes (safe to call multiple times)
- (void)stop;

/// Get current clipboard string (UTF-8). Returns nil if no plain text is available.
- (nullable NSString *)currentString;

/// Set clipboard string (UTF-8). Internally tries to avoid self-triggered callback loops.
- (void)setString:(NSString *)text;

/// Set clipboard string originating from a remote VNC client. This avoids echo by
/// skipping the immediate local callback and the subsequent system notification once.
- (void)setStringFromRemote:(NSString *)text;

/// Clipboard change callback (executed on the main thread; text is nil when no plain text).
@property (atomic, copy, nullable) void (^onChange)(NSString *_Nullable text);

@end

NS_ASSUME_NONNULL_END
