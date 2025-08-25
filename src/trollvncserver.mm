//
// trollvncserver.mm
// iOS VNC server entrypoint and display pipeline.
//
// Responsibilities in this step:
// - Initialize LibVNCServer with a 32-bit ARGB framebuffer.
// - Capture iOS screen frames via ScreenCapturer.
// - Copy frames into a tightly-packed double buffer and notify VNC clients.
// - Minimal, production-lean CLI parsing with getopt (-p, -n, -v, -h).
//

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import <Accelerate/Accelerate.h>
#import <rfb/keysym.h>
#import <rfb/rfb.h>

#import <atomic>
#import <errno.h>
#import <pthread.h>
#import <signal.h>
#import <stdbool.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#import "STHIDEventGenerator.h"
#import "ScreenCapturer.h"

#if DEBUG
#define TVLog(fmt, ...) NSLog((@"%s:%d " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__)
#else
#define TVLog(...)
#endif

// MARK: - Globals

static rfbScreenInfoPtr gScreen = NULL;
static void *gFrontBuffer = NULL; // Exposed to VNC clients via gScreen->frameBuffer
static void *gBackBuffer = NULL;  // We render into this and then swap
static size_t gFBSize = 0;        // bytes
static int gWidth = 0;
static int gHeight = 0;
static int gSrcWidth = 0;      // capture source width
static int gSrcHeight = 0;     // capture source height
static int gBytesPerPixel = 4; // ARGB/BGRA 32-bit
static volatile sig_atomic_t gShouldTerminate = 0;
static int gClientCount = 0;        // Number of connected clients
static BOOL gIsCaptureStarted = NO; // Whether ScreenCapturer has been started

// Capture globals
static ScreenCapturer *gCapturer = nil;
static void (^gFrameHandler)(CMSampleBufferRef) = nil;

// CLI options
static int gPort = 5901; // Default LibVNCServer port (adjust as needed)
static BOOL gViewOnly = NO;
static NSString *gDesktopName = @"TrollVNC";
static BOOL gAsyncSwapEnabled = NO;          // Enable non-blocking swap (may cause tearing)
static int gTileSize = 32;                   // Tile size for dirty detection (pixels)
static int gFullscreenThresholdPercent = 30; // If changed tiles exceed this %, update full screen
static int gMaxRectsLimit = 256;             // Max rects before falling back to bbox/fullscreen
static double gDeferWindowSec = 0.015;       // Coalescing window; 0 disables deferral
static int gMaxInflightUpdates = 1;          // Max concurrent client encodes; drop frames if >= this
static double gScale = 1.0;                  // 0 < scale <= 1.0, 1.0 = no scaling
static BOOL gKeyEventLogging = NO;           // Log keyboard events (keysym, mapping)
// Modifier mapping scheme: 0 = standard (Alt->Option, Meta/Super->Command), 1 = Alt-as-Command
static int gModMapScheme = 0;

// Tiling/Hashing state
static int gTilesX = 0;
static int gTilesY = 0;
static size_t gTileCount = 0;
static uint64_t *gPrevHash = NULL;
static uint64_t *gCurrHash = NULL;
static uint8_t *gPendingDirty = NULL; // per-tile pending dirty mask
static CFAbsoluteTime gDeferStartTime = 0;
static BOOL gHasPending = NO;
static std::atomic<int> gInflight(0);

// Wheel scroll coalescing state (async, non-blocking)
static dispatch_queue_t gWheelQueue = nil; // serial queue for wheel gestures
static double gWheelAccumPx = 0.0;         // accumulated scroll in pixels (+down, -up)
static BOOL gWheelFlushScheduled = NO;     // whether a flush is pending
static double gWheelStepPx = 48.0;         // base pixels per wheel tick (lower = slower)
static double gWheelCoalesceSec = 0.03;    // coalescing window
static double gWheelMaxStepPx = 192.0;     // base max distance per flush (pre-clamp)
static double gWheelAbsClampFactor = 2.5;  // absolute clamp = factor * gWheelMaxStepPx
static double gWheelAmpCoeff = 0.18;       // velocity amplification coefficient
static double gWheelAmpCap = 0.75;         // max extra amplification (0..1)
static double gWheelMinTakeRatio = 0.35;   // minimum take distance vs step size
static double gWheelDurBase = 0.05;        // duration base seconds
static double gWheelDurK = 0.00016;        // duration factor applied to sqrt(distance)
static double gWheelDurMin = 0.05;         // duration clamp min
static double gWheelDurMax = 0.14;         // duration clamp max
static BOOL gWheelNaturalDir = NO;         // natural scroll direction (invert delta)
static void wheel_schedule_flush(CGPoint anchor, double delaySec);

static void parseWheelOptions(const char *spec) {
    if (!spec)
        return;
    char *dup = strdup(spec);
    if (!dup)
        return;
    char *saveptr = NULL;
    for (char *tok = strtok_r(dup, ",", &saveptr); tok; tok = strtok_r(NULL, ",", &saveptr)) {
        char *eq = strchr(tok, '=');
        if (!eq)
            continue;
        *eq = '\0';
        const char *key = tok;
        const char *val = eq + 1;
        double d = strtod(val, NULL);
        if (strcmp(key, "step") == 0) {
            if (d > 0)
                gWheelStepPx = d;
        } else if (strcmp(key, "coalesce") == 0) {
            if (d >= 0 && d <= 0.5)
                gWheelCoalesceSec = d;
        } else if (strcmp(key, "max") == 0) {
            if (d > 0)
                gWheelMaxStepPx = d;
        } else if (strcmp(key, "clamp") == 0) {
            if (d >= 1.0 && d <= 10.0)
                gWheelAbsClampFactor = d;
        } else if (strcmp(key, "amp") == 0) {
            if (d >= 0.0 && d <= 5.0)
                gWheelAmpCoeff = d;
        } else if (strcmp(key, "cap") == 0) {
            if (d >= 0.0 && d <= 2.0)
                gWheelAmpCap = d;
        } else if (strcmp(key, "minratio") == 0) {
            if (d >= 0.0 && d <= 2.0)
                gWheelMinTakeRatio = d;
        } else if (strcmp(key, "durbase") == 0) {
            if (d >= 0.0 && d <= 1.0)
                gWheelDurBase = d;
        } else if (strcmp(key, "durk") == 0) {
            if (d >= 0.0 && d <= 1.0)
                gWheelDurK = d;
        } else if (strcmp(key, "durmin") == 0) {
            if (d >= 0.0 && d <= 1.0)
                gWheelDurMin = d;
        } else if (strcmp(key, "durmax") == 0) {
            if (d >= 0.0 && d <= 2.0)
                gWheelDurMax = d;
        } else if (strcmp(key, "natural") == 0) {
            gWheelNaturalDir = (d != 0.0);
        }
    }
    free(dup);
}

// Forward declarations
static void installSignalHandlers(void);
static void handleSignal(int signum);
static void cleanupAndExit(int code);
static inline void resetCurrTileHashes(void);

// Expose private methods we use from STHIDEventGenerator
@interface STHIDEventGenerator (Private)
- (void)touchDownAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
- (void)liftUpAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
- (void)_updateTouchPoints:(CGPoint *)points count:(NSUInteger)count;
@end

// MARK: - Input helpers

static inline CGPoint vncPointToDevicePoint(int vx, int vy) {
    // Map from VNC framebuffer space (gWidth x gHeight) to device capture space (gSrcWidth x gSrcHeight)
    double sx = (gWidth > 0) ? ((double)gSrcWidth / (double)gWidth) : 1.0;
    double sy = (gHeight > 0) ? ((double)gSrcHeight / (double)gHeight) : 1.0;
    double dx = sx * (double)vx;
    double dy = sy * (double)vy;
    if (dx < 0)
        dx = 0;
    if (dy < 0)
        dy = 0;
    if (dx > (double)(gSrcWidth - 1))
        dx = (double)(gSrcWidth - 1);
    if (dy > (double)(gSrcHeight - 1))
        dy = (double)(gSrcHeight - 1);
    return CGPointMake((CGFloat)dx, (CGFloat)dy);
}

static NSString *keysymToString(rfbKeySym ks) {
    // Alphanumeric and basic ASCII
    if ((ks >= 0x20 && ks <= 0x7E) || ks == ' ') {
        unichar ch = (unichar)ks;
        return [NSString stringWithCharacters:&ch length:1];
    }
    switch (ks) {
    case XK_Return:
    case XK_KP_Enter:
        return @"RETURN";
    case XK_Tab:
        return @"TAB";
    case XK_Escape:
        return @"ESCAPE";
    case XK_BackSpace:
        return @"BACKSPACE";
    case XK_Delete:
        return @"FORWARDDELETE";
    case XK_Insert:
        return @"INSERT";
    case XK_Home:
        return @"HOME";
    case XK_End:
        return @"END";
    case XK_Page_Up:
        return @"PAGEUP";
    case XK_Page_Down:
        return @"PAGEDOWN";
    case XK_Left:
        return @"LEFTARROW";
    case XK_Right:
        return @"RIGHTARROW";
    case XK_Up:
        return @"UPARROW";
    case XK_Down:
        return @"DOWNARROW";
    case XK_space:
        return @" ";
    case XK_Shift_L:
        return @"LEFTSHIFT";
    case XK_Shift_R:
        return @"RIGHTSHIFT";
    case XK_Control_L:
        return @"LEFTCONTROL";
    case XK_Control_R:
        return @"RIGHTCONTROL";
    // Modifier mapping depending on scheme
    case XK_Alt_L:
        return (gModMapScheme == 1) ? @"LEFTCOMMAND" : @"LEFTALT"; // Option or Command
    case XK_Alt_R:
        return (gModMapScheme == 1) ? @"RIGHTCOMMAND" : @"RIGHTALT"; // Option or Command
    case XK_ISO_Level3_Shift:
        return @"LEFTALT"; // macOS left Option often sent as ISO_Level3_Shift
    case XK_Mode_switch:
        return @"RIGHTALT"; // Mode switch often behaves like AltGr
    case XK_Meta_L:
        return (gModMapScheme == 1) ? @"LEFTALT" : @"LEFTCOMMAND"; // Option or Command
    case XK_Meta_R:
        return (gModMapScheme == 1) ? @"RIGHTALT" : @"RIGHTCOMMAND"; // Option or Command
    case XK_Super_L:
        return @"LEFTCOMMAND"; // Treat Super as Command in both schemes
    case XK_Super_R:
        return @"RIGHTCOMMAND";
    default:
        break;
    }
    // Function keys XK_F1..XK_F24
    if (ks >= XK_F1 && ks <= XK_F24) {
        int idx = (int)(ks - XK_F1) + 1;
        return [NSString stringWithFormat:@"F%d", idx];
    }
    return nil;
}

// Track last button state to detect edges; per-process (typical single client).
static int gLastButtonMask = 0;

static void ptrAddEvent(int buttonMask, int x, int y, rfbClientPtr cl) {
    (void)cl;
    if (gViewOnly)
        return;
    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];
    CGPoint pt = vncPointToDevicePoint(x, y);

    // Left button (bit 0)
    bool leftNow = (buttonMask & 1) != 0;
    bool leftPrev = (gLastButtonMask & 1) != 0;
    if (leftNow && !leftPrev) {
        [gen touchDownAtPoints:&pt touchCount:1];
    } else if (!leftNow && leftPrev) {
        [gen liftUpAtPoints:&pt touchCount:1];
    } else if (leftNow) {
        CGPoint p = pt;
        [gen _updateTouchPoints:&p count:1];
    }

    // Middle button (bit 1 -> mask 2): map to Power key
    bool midNow = (buttonMask & 2) != 0;
    bool midPrev = (gLastButtonMask & 2) != 0;
    if (midNow && !midPrev) {
        [gen powerDown];
    } else if (!midNow && midPrev) {
        [gen powerUp];
    }

    // Right button (bit 2 -> mask 4): map to Home/Menu key
    bool rightNow = (buttonMask & 4) != 0;
    bool rightPrev = (gLastButtonMask & 4) != 0;
    if (rightNow && !rightPrev) {
        [gen menuDown];
    } else if (!rightNow && rightPrev) {
        [gen menuUp];
    }

    // Wheel emulation: coalesce ticks and perform async flicks off the VNC thread.
    bool wheelUpNow = (buttonMask & 8) != 0;  // button 4
    bool wheelDnNow = (buttonMask & 16) != 0; // button 5
    bool wheelUpPrev = (gLastButtonMask & 8) != 0;
    bool wheelDnPrev = (gLastButtonMask & 16) != 0;
    if (!gWheelQueue) {
        gWheelQueue = dispatch_queue_create("com.82flex.trollvnc.wheel", DISPATCH_QUEUE_SERIAL);
    }
    if ((wheelUpNow && !wheelUpPrev) || (wheelDnNow && !wheelDnPrev)) {
        double delta = (wheelDnNow && !wheelDnPrev) ? +gWheelStepPx : -gWheelStepPx;
        if (gWheelNaturalDir)
            delta = -delta;
        dispatch_async(gWheelQueue, ^{
            gWheelAccumPx += delta;
            if (!gWheelFlushScheduled) {
                gWheelFlushScheduled = YES;
                wheel_schedule_flush(pt, gWheelCoalesceSec);
            }
        });
    }

    gLastButtonMask = buttonMask;
}

static void wheel_schedule_flush(CGPoint anchorPoint, double delaySec) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), gWheelQueue, ^{
        // Consume the entire accumulation in one gesture to avoid many small drags.
        double takeRaw = gWheelAccumPx;
        gWheelAccumPx = 0.0; // zero out
        gWheelFlushScheduled = NO;
        double mag = fabs(takeRaw);
        if (mag < 1.0)
            return;

        // Velocity-like amplification: for larger accumulations (faster wheel),
        // slightly increase distance instead of emitting many short drags.
        double amp = 1.0 + fmin(gWheelAmpCap, gWheelAmpCoeff * log1p(mag / fmax(gWheelStepPx, 1.0)));
        double take = copysign(mag * amp, takeRaw);
        // Guarantee a small-but-meaningful movement for tiny scrolls
        if (fabs(take) < (gWheelMinTakeRatio * gWheelStepPx)) {
            take = copysign(gWheelMinTakeRatio * gWheelStepPx, take);
        }
        // Absolute clamp for safety
        double absClamp = gWheelMaxStepPx * gWheelAbsClampFactor;
        if (take > absClamp)
            take = absClamp;
        if (take < -absClamp)
            take = -absClamp;

        CGFloat endY = anchorPoint.y + (CGFloat)take;
        if (endY < 0)
            endY = 0;
        CGFloat maxY = (CGFloat)gSrcHeight - 1;
        if (endY > maxY)
            endY = maxY;
        CGPoint endPt = CGPointMake(anchorPoint.x, endY);
        // Duration scales sub-linearly with distance; parameters configurable
        double dur = gWheelDurBase + gWheelDurK * sqrt(fabs(take));
        if (dur > gWheelDurMax)
            dur = gWheelDurMax;
        if (dur < gWheelDurMin)
            dur = gWheelDurMin;
        [[STHIDEventGenerator sharedGenerator] dragLinearWithStartPoint:anchorPoint endPoint:endPt duration:dur];
    });
}

static void kbdAddEvent(rfbBool down, rfbKeySym keySym, rfbClientPtr cl) {
    (void)cl;
    if (gViewOnly)
        return;
    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];
    NSString *keyStr = keysymToString(keySym);
    if (gKeyEventLogging) {
        const char *mapped = keyStr ? [keyStr UTF8String] : "(nil)";
        fprintf(stderr, "[key] %s keysym=0x%lx (%lu) mapped=%s\n", down ? "down" : " up ", (unsigned long)keySym,
                (unsigned long)keySym, mapped);
    }
    if (!keyStr)
        return;
    if (down)
        [gen keyDown:keyStr];
    else
        [gen keyUp:keyStr];
}

// MARK: - Helpers

static void swapBuffers(void) {
    void *tmp = gFrontBuffer;
    gFrontBuffer = gBackBuffer;
    gBackBuffer = tmp;
    gScreen->frameBuffer = (char *)gFrontBuffer;
}

// Try to acquire all clients' sendMutex without blocking.
// Returns 1 on success and fills locked[] with acquired mutexes (count in *lockedCount),
// otherwise returns 0 and releases any partial locks.
static int tryLockAllClients(pthread_mutex_t **locked, size_t *lockedCount, size_t capacity) {
    *lockedCount = 0;
    rfbClientIteratorPtr it = rfbGetClientIterator(gScreen);
    rfbClientPtr cl;
    int ok = 1;
    while ((cl = rfbClientIteratorNext(it))) {
        if (*lockedCount >= capacity) {
            ok = 0;
            break;
        }
        pthread_mutex_t *m = &cl->sendMutex;
        if (pthread_mutex_trylock(m) == 0) {
            locked[(*lockedCount)++] = m;
        } else {
            ok = 0;
            break;
        }
    }
    rfbReleaseClientIterator(it);
    if (!ok) {
        // release any that were acquired
        for (size_t i = 0; i < *lockedCount; ++i) {
            pthread_mutex_unlock(locked[i]);
        }
        *lockedCount = 0;
        return 0;
    }
    return 1;
}

// Blocking lock helpers (original behavior): lock all clients, then unlock all.
static void lockAllClientsBlocking(void) {
    rfbClientIteratorPtr it = rfbGetClientIterator(gScreen);
    rfbClientPtr cl;
    while ((cl = rfbClientIteratorNext(it))) {
        pthread_mutex_lock(&cl->sendMutex);
    }
    rfbReleaseClientIterator(it);
}

static void unlockAllClientsBlocking(void) {
    rfbClientIteratorPtr it = rfbGetClientIterator(gScreen);
    rfbClientPtr cl;
    while ((cl = rfbClientIteratorNext(it))) {
        pthread_mutex_unlock(&cl->sendMutex);
    }
    rfbReleaseClientIterator(it);
}

// MARK: - Dirty tiles and rects

static inline uint64_t fnv1a_update(uint64_t h, const uint8_t *data, size_t len) {
    const uint64_t FNV_PRIME = 1099511628211ULL;
    for (size_t i = 0; i < len; ++i) {
        h ^= (uint64_t)data[i];
        h *= FNV_PRIME;
    }
    return h;
}

static inline uint64_t fnv1a_basis(void) { return 1469598103934665603ULL; }

// Hash tiles from an existing buffer (no copy)
static void hashTiledFromBuffer(const uint8_t *buf, int width, int height, size_t bpr) {
    resetCurrTileHashes();
    for (int y = 0; y < height; ++y) {
        int ty = y / gTileSize;
        for (int tx = 0; tx < gTilesX; ++tx) {
            int startX = tx * gTileSize;
            if (startX >= width)
                break;
            int endX = startX + gTileSize;
            if (endX > width)
                endX = width;
            size_t offset = (size_t)startX * (size_t)gBytesPerPixel;
            size_t length = (size_t)(endX - startX) * (size_t)gBytesPerPixel;
            size_t tileIndex = (size_t)ty * (size_t)gTilesX + (size_t)tx;
            gCurrHash[tileIndex] = fnv1a_update(gCurrHash[tileIndex], buf + (size_t)y * bpr + offset, length);
        }
    }
}

static void initTilingOrReset(void) {
    int tilesX = (gWidth + gTileSize - 1) / gTileSize;
    int tilesY = (gHeight + gTileSize - 1) / gTileSize;
    size_t tileCount = (size_t)tilesX * (size_t)tilesY;
    if (tilesX != gTilesX || tilesY != gTilesY || tileCount != gTileCount || !gPrevHash || !gCurrHash) {
        free(gPrevHash);
        free(gCurrHash);
        if (gPendingDirty) {
            free(gPendingDirty);
            gPendingDirty = NULL;
        }
        gPrevHash = (uint64_t *)malloc(tileCount * sizeof(uint64_t));
        gCurrHash = (uint64_t *)malloc(tileCount * sizeof(uint64_t));
        gPendingDirty = (uint8_t *)malloc(tileCount);
        if (!gPrevHash || !gCurrHash) {
            fprintf(stderr, "Out of memory for tile hashes.\n");
            exit(EXIT_FAILURE);
        }
        for (size_t i = 0; i < tileCount; ++i) {
            gPrevHash[i] = 0; // force full update first frame
            gCurrHash[i] = fnv1a_basis();
        }
        gTilesX = tilesX;
        gTilesY = tilesY;
        gTileCount = tileCount;
        if (gPendingDirty)
            memset(gPendingDirty, 0, gTileCount);
    } else {
        for (size_t i = 0; i < gTileCount; ++i) {
            gCurrHash[i] = fnv1a_basis();
        }
    }
}

// Copy with stride while updating per-tile hashes for curr frame
static void copyAndHashTiled(uint8_t *dstTight, const uint8_t *src, int copyW, int copyH, size_t srcBPR) {
    size_t dstBPR = (size_t)copyW * (size_t)gBytesPerPixel;
    for (int y = 0; y < copyH; ++y) {
        // Copy the whole line into tight buffer
        memcpy(dstTight + (size_t)y * dstBPR, src + (size_t)y * srcBPR, dstBPR);

        // Update tile hashes for this line
        int ty = y / gTileSize;
        int tileRowStartY = ty * gTileSize;
        (void)tileRowStartY; // not used further, but kept for clarity
        for (int tx = 0; tx < gTilesX; ++tx) {
            int startX = tx * gTileSize;
            if (startX >= copyW)
                break;
            int endX = startX + gTileSize;
            if (endX > copyW)
                endX = copyW;
            size_t offset = (size_t)startX * (size_t)gBytesPerPixel;
            size_t length = (size_t)(endX - startX) * (size_t)gBytesPerPixel;
            size_t tileIndex = (size_t)ty * (size_t)gTilesX + (size_t)tx;
            gCurrHash[tileIndex] = fnv1a_update(gCurrHash[tileIndex], src + (size_t)y * srcBPR + offset, length);
        }
    }
}

typedef struct {
    int x, y, w, h;
} DirtyRect;

// Build dirty rectangles from tile hash diffs. Returns number of rects written, up to maxRects.
static int buildDirtyRects(DirtyRect *rects, int maxRects, int *outChangedTiles) {
    int rectCount = 0;
    int changedTiles = 0;
    // First pass: horizontal merge per tile row
    for (int ty = 0; ty < gTilesY; ++ty) {
        int tx = 0;
        while (tx < gTilesX) {
            size_t idx = (size_t)ty * (size_t)gTilesX + (size_t)tx;
            int changed = (gCurrHash[idx] != gPrevHash[idx]);
            if (!changed) {
                tx++;
                continue;
            }
            // Start of a run
            int runStart = tx;
            changedTiles++;
            tx++;
            while (tx < gTilesX) {
                size_t idx2 = (size_t)ty * (size_t)gTilesX + (size_t)tx;
                if (gCurrHash[idx2] != gPrevHash[idx2]) {
                    changedTiles++;
                    tx++;
                } else
                    break;
            }
            // Emit rect for this horizontal run
            if (rectCount < maxRects) {
                int x = runStart * gTileSize;
                int w = (tx - runStart) * gTileSize;
                int y = ty * gTileSize;
                int h = gTileSize;
                // Clip to screen bounds
                if (x + w > gWidth)
                    w = gWidth - x;
                if (y + h > gHeight)
                    h = gHeight - y;
                rects[rectCount++] = (DirtyRect){x, y, w, h};
            } else {
                // Too many rects; caller may fallback to fullscreen
                if (outChangedTiles)
                    *outChangedTiles = changedTiles;
                return rectCount;
            }
        }
    }

    // Optional vertical merge: merge rects with same x,w and contiguous vertically
    // Simple O(n^2) merge for small rect counts
    for (int i = 0; i < rectCount; ++i) {
        for (int j = i + 1; j < rectCount; ++j) {
            if (rects[j].w == 0 || rects[j].h == 0)
                continue;
            if (rects[i].x == rects[j].x && rects[i].w == rects[j].w) {
                if (rects[i].y + rects[i].h == rects[j].y) {
                    rects[i].h += rects[j].h;
                    rects[j].w = rects[j].h = 0; // mark removed
                } else if (rects[j].y + rects[j].h == rects[i].y) {
                    rects[j].h += rects[i].h;
                    rects[i].w = rects[i].h = 0;
                }
            }
        }
    }

    // Compact removed entries
    int k = 0;
    for (int i = 0; i < rectCount; ++i) {
        if (rects[i].w > 0 && rects[i].h > 0)
            rects[k++] = rects[i];
    }
    rectCount = k;

    if (outChangedTiles)
        *outChangedTiles = changedTiles;
    return rectCount;
}

static inline void swapTileHashes(void) {
    uint64_t *tmp = gPrevHash;
    gPrevHash = gCurrHash;
    gCurrHash = tmp;
}

static inline void resetCurrTileHashes(void) {
    if (!gCurrHash || gTileCount == 0)
        return;
    uint64_t basis = fnv1a_basis();
    for (size_t i = 0; i < gTileCount; ++i) {
        gCurrHash[i] = basis;
    }
}

// Accumulate pending dirty tiles for time-based coalescing
static void accumulatePendingDirty(void) {
    if (!gPendingDirty)
        return;
    for (size_t i = 0; i < gTileCount; ++i) {
        if (gCurrHash[i] != gPrevHash[i])
            gPendingDirty[i] = 1;
    }
}

// Build rects from pending mask by temporarily mapping to hashes
static int buildRectsFromPending(DirtyRect *rects, int maxRects) {
    if (!gPendingDirty)
        return 0;
    // Temporarily mark curr!=prev for pending tiles
    // Save originals
    // For efficiency, we only synthesize gCurrHash markers without touching buffers
    size_t changed = 0;
    for (size_t i = 0; i < gTileCount; ++i) {
        if (gPendingDirty[i]) {
            if (gCurrHash[i] == gPrevHash[i])
                gCurrHash[i] ^= 0x1ULL;
            changed++;
        }
    }
    int dummyTiles = 0;
    int cnt = buildDirtyRects(rects, maxRects, &dummyTiles);
    // Restore hashes for tiles we toggled
    for (size_t i = 0; i < gTileCount; ++i) {
        if (gPendingDirty[i]) {
            if (gCurrHash[i] == gPrevHash[i])
                gCurrHash[i] ^= 0x1ULL; // unlikely path
            else if ((gCurrHash[i] ^ 0x1ULL) == gPrevHash[i])
                gCurrHash[i] ^= 0x1ULL;
        }
    }
    (void)changed;
    return cnt;
}

static void markRectsModified(DirtyRect *rects, int rectCount) {
    for (int i = 0; i < rectCount; ++i) {
        rfbMarkRectAsModified(gScreen, rects[i].x, rects[i].y, rects[i].x + rects[i].w, rects[i].y + rects[i].h);
    }
}

static void copyRectsFromBackToFront(DirtyRect *rects, int rectCount) {
    size_t fbBPR = (size_t)gWidth * (size_t)gBytesPerPixel;
    for (int i = 0; i < rectCount; ++i) {
        int x = rects[i].x, y = rects[i].y, w = rects[i].w, h = rects[i].h;
        size_t rowBytes = (size_t)w * (size_t)gBytesPerPixel;
        for (int r = 0; r < h; ++r) {
            uint8_t *dst = (uint8_t *)gFrontBuffer + (size_t)(y + r) * fbBPR + (size_t)x * gBytesPerPixel;
            uint8_t *src = (uint8_t *)gBackBuffer + (size_t)(y + r) * fbBPR + (size_t)x * gBytesPerPixel;
            memcpy(dst, src, rowBytes);
        }
    }
}

// Row-by-row copy to convert a possibly-strided captured buffer into a tightly packed VNC buffer.
static void copyWithStrideTight(uint8_t *dstTight, const uint8_t *src, int width, int height, size_t srcBytesPerRow) {
    size_t dstBPR = (size_t)width * gBytesPerPixel;
    for (int y = 0; y < height; ++y) {
        memcpy(dstTight + (size_t)y * dstBPR, src + (size_t)y * srcBytesPerRow, dstBPR);
    }
}

// MARK: - LibVNCServer callbacks (input disabled in this step)

static void clientGone(rfbClientPtr cl) {
    // Decrement client count and stop capture if this was the last client.
    if (gClientCount > 0)
        gClientCount--;
    TVLog(@"Client disconnected, active clients=%d", gClientCount);

    if (gIsCaptureStarted && gClientCount == 0 && gCapturer) {
        [gCapturer endCapture];
        gIsCaptureStarted = NO;
        TVLog(@"No clients remaining; screen capture stopped.");
    }
}

static enum rfbNewClientAction newClient(rfbClientPtr cl) {
    cl->clientGoneHook = clientGone;
    cl->viewOnly = gViewOnly ? TRUE : FALSE;

    gClientCount++;
    TVLog(@"Client connected, active clients=%d", gClientCount);

    if (!gIsCaptureStarted && gClientCount > 0 && gCapturer && gFrameHandler) {
        // Start capture when entering non-zero client population.
        gIsCaptureStarted = YES;
        [gCapturer startCaptureWithFrameHandler:gFrameHandler];
        TVLog(@"Screen capture started (clients=%d).", gClientCount);
    }
    return RFB_CLIENT_ACCEPT;
}

// Track encode life-cycle to provide backpressure via inflight counter
static void displayHook(rfbClientPtr cl) {
    (void)cl;
    gInflight.fetch_add(1, std::memory_order_relaxed);
}

static void displayFinishedHook(rfbClientPtr cl, int result) {
    (void)cl;
    (void)result;
    gInflight.fetch_sub(1, std::memory_order_relaxed);
}

// MARK: - CLI

static void printUsageAndExit(const char *prog) {
    fprintf(stderr,
            "Usage: %s [-p port] [-n name] [-v] [-a] [-t size] [-P pct] [-R max] [-d sec] [-Q n] [-s scale] [-W px] "
            "[-w k=v,...] [-N] [-M scheme] [-K] [-h]\n",
            prog);
    fprintf(stderr, "  -p port   TCP port for VNC (default: %d)\n", gPort);
    fprintf(stderr, "  -n name   Desktop name shown to clients (default: %s)\n", [gDesktopName UTF8String]);
    fprintf(stderr, "  -v        View-only (ignore input)\n");
    fprintf(stderr, "  -a        Enable non-blocking swap (may cause tearing)\n");
    fprintf(stderr, "  -t size   Tile size for dirty-detection (8..128, default: %d)\n", gTileSize);
    fprintf(stderr, "  -P pct    Fullscreen fallback threshold percent (1..100, default: %d)\n",
            gFullscreenThresholdPercent);
    fprintf(stderr, "  -R max    Max dirty rects before falling back to bounding-box (default: %d)\n", gMaxRectsLimit);
    fprintf(stderr, "  -d sec    Defer update window in seconds (0..0.5, default: %.3f)\n", gDeferWindowSec);
    fprintf(stderr, "  -Q n      Max in-flight updates before dropping new frames (0 disables, default: %d)\n",
            gMaxInflightUpdates);
    fprintf(stderr, "  -s scale  Output scale factor 0<s<=1 (default: %.2f, 1 means no scaling)\n", gScale);
    fprintf(stderr, "  -W px     Wheel step in pixels per tick (default: %.0f)\n", gWheelStepPx);
    fprintf(stderr, "  -w k=v,.. Wheel tuning: step,coalesce,max,clamp,amp,cap,minratio,durbase,durk,durmin,durmax\n");
    fprintf(stderr, "  -N        Natural scroll direction (invert wheel delta)\n");
    fprintf(stderr, "  -M scheme Modifier mapping: std|altcmd (default: std)\n");
    fprintf(stderr, "  -K        Log keyboard events (keysym -> mapping) to stderr\n");
    fprintf(stderr, "  -h        Show help\n\n");
    rfbUsage();
    exit(EXIT_SUCCESS);
}

static void parseCLI(int argc, const char *argv[]) {
    int opt;
    while ((opt = getopt(argc, (char *const *)argv, "p:n:vhat:P:R:d:Q:s:W:w:NM:K")) != -1) {
        switch (opt) {
        case 'N': {
            gWheelNaturalDir = YES;
            break;
        }
        case 'p': {
            long port = strtol(optarg, NULL, 10);
            if (port <= 0 || port > 65535) {
                fprintf(stderr, "Invalid port: %s\n", optarg);
                exit(EXIT_FAILURE);
            }
            gPort = (int)port;
            break;
        }
        case 'n':
            gDesktopName = [NSString stringWithUTF8String:optarg ?: "TrollVNC"];
            break;
        case 'v':
            gViewOnly = YES;
            break;
        case 'a':
            gAsyncSwapEnabled = YES;
            break;
        case 't': {
            long ts = strtol(optarg, NULL, 10);
            if (ts < 8 || ts > 128) {
                fprintf(stderr, "Invalid tile size: %s (expected 8..128)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gTileSize = (int)ts;
            break;
        }
        case 'P': {
            long p = strtol(optarg, NULL, 10);
            if (p < 1 || p > 100) {
                fprintf(stderr, "Invalid threshold percent: %s (expected 1..100)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gFullscreenThresholdPercent = (int)p;
            break;
        }
        case 'R': {
            long m = strtol(optarg, NULL, 10);
            if (m < 1 || m > 4096) {
                fprintf(stderr, "Invalid max rects: %s (expected 1..4096)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gMaxRectsLimit = (int)m;
            break;
        }
        case 'd': {
            double s = strtod(optarg, NULL);
            if (s < 0.0 || s > 0.5) {
                fprintf(stderr, "Invalid defer window seconds: %s (expected 0..0.5)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gDeferWindowSec = s;
            break;
        }
        case 'Q': {
            long q = strtol(optarg, NULL, 10);
            if (q < 0 || q > 8) {
                fprintf(stderr, "Invalid max in-flight: %s (expected 0..8)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gMaxInflightUpdates = (int)q;
            break;
        }
        case 's': {
            double sc = strtod(optarg, NULL);
            if (!(sc > 0.0 && sc <= 1.0)) {
                fprintf(stderr, "Invalid scale: %s (expected 0 < s <= 1)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gScale = sc;
            break;
        }
        case 'W': {
            double px = strtod(optarg, NULL);
            if (!(px > 4.0 && px <= 1000.0)) {
                fprintf(stderr, "Invalid wheel step px: %s (expected >4..<=1000)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gWheelStepPx = px;
            // Scale max step roughly 4x and adjust duration slope mildly
            gWheelMaxStepPx = fmax(2.0 * gWheelStepPx, 96.0) * 1.0;
            break;
        }
        case 'w': {
            parseWheelOptions(optarg);
            break;
        }
        case 'M': {
            const char *val = optarg ? optarg : "std";
            if (strcmp(val, "std") == 0)
                gModMapScheme = 0;
            else if (strcmp(val, "altcmd") == 0)
                gModMapScheme = 1;
            else {
                fprintf(stderr, "Invalid -M scheme: %s (expected std|altcmd)\n", val);
                exit(EXIT_FAILURE);
            }
            break;
        }
        case 'K': {
            gKeyEventLogging = YES;
            break;
        }
        case 'h':
        default:
            printUsageAndExit(argv[0]);
            break;
        }
    }
}

// MARK: - Main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // 1) Parse CLI early for port/name/viewOnly
        parseCLI(argc, argv);

        // 2) Determine framebuffer geometry from ScreenCapturer
        NSDictionary *props = [ScreenCapturer sharedRenderProperties];
        gSrcWidth = [props[(__bridge NSString *)kIOSurfaceWidth] intValue];
        gSrcHeight = [props[(__bridge NSString *)kIOSurfaceHeight] intValue];
        if (gSrcWidth <= 0 || gSrcHeight <= 0) {
            fprintf(stderr, "Failed to resolve screen size from ScreenCapturer properties.\n");
            return EXIT_FAILURE;
        }
        // Apply output scaling if requested
        if (gScale > 0.0 && gScale < 1.0) {
            gWidth = MAX(1, (int)floor((double)gSrcWidth * gScale));
            gHeight = MAX(1, (int)floor((double)gSrcHeight * gScale));
        } else {
            gWidth = gSrcWidth;
            gHeight = gSrcHeight;
        }
        gFBSize = (size_t)gWidth * (size_t)gHeight * (size_t)gBytesPerPixel;

        // 3) Allocate double buffers (tightly packed BGRA/ARGB32)
        gFrontBuffer = calloc(1, gFBSize);
        gBackBuffer = calloc(1, gFBSize);
        if (!gFrontBuffer || !gBackBuffer) {
            fprintf(stderr, "Failed to allocate framebuffers (%dx%d).\n", gWidth, gHeight);
            return EXIT_FAILURE;
        }

        // 4) Initialize LibVNCServer
        int argcCopy = argc; // rfbGetScreen may modify argc/argv
        char **argvCopy = (char **)argv;
        int bitsPerSample = 8;
        gScreen = rfbGetScreen(&argcCopy, argvCopy, gWidth, gHeight, bitsPerSample, 3, gBytesPerPixel);
        if (!gScreen) {
            fprintf(stderr, "LibVNCServer: rfbGetScreen failed.\n");
            return EXIT_FAILURE;
        }

        // BGRA (little-endian) layout
        gScreen->serverFormat.redShift = bitsPerSample * 2;   // 16
        gScreen->serverFormat.greenShift = bitsPerSample * 1; // 8
        gScreen->serverFormat.blueShift = 0;
        gScreen->desktopName = strdup([gDesktopName UTF8String]);
        gScreen->frameBuffer = (char *)gFrontBuffer;
        gScreen->port = gPort;
        gScreen->newClientHook = newClient;
        gScreen->displayHook = displayHook;
        gScreen->displayFinishedHook = displayFinishedHook;

        // Input handlers: route VNC events to STHIDEventGenerator
        gScreen->ptrAddEvent = ptrAddEvent;
        gScreen->kbdAddEvent = kbdAddEvent;

        // Cursor: we capture the cursor in the framebuffer already.
        gScreen->cursor = NULL;

        rfbInitServer(gScreen);
        TVLog(@"VNC server initialized on port %d, %dx%d, name '%@'", gPort, gWidth, gHeight, gDesktopName);

        // Run VNC in background thread
        rfbRunEventLoop(gScreen, -1, TRUE);

        // 5) Install signal handlers for graceful shutdown
        installSignalHandlers();

        // 6) Prepare screen capture, but DO NOT start yet; start on first client connect
        initTilingOrReset();
        gCapturer = [ScreenCapturer sharedCapturer];
        gFrameHandler = ^(CMSampleBufferRef _Nonnull sampleBuffer) {
            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (!pb)
                return;

            // Busy-drop: if encoders are busy and limit reached, skip this frame (disabled when -Q 0)
            if (gMaxInflightUpdates > 0 && gInflight.load(std::memory_order_relaxed) >= gMaxInflightUpdates) {
                if (gScale == 1.0) {
                    // Advance hash basis without copying to keep pending detection sane
                    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                    const uint8_t *baseRO = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
                    const size_t srcBPRRO = (size_t)CVPixelBufferGetBytesPerRow(pb);
                    const int copyWRO = MIN((int)CVPixelBufferGetWidth(pb), gWidth);
                    const int copyHRO = MIN((int)CVPixelBufferGetHeight(pb), gHeight);
                    resetCurrTileHashes();
                    for (int y = 0; y < copyHRO; ++y) {
                        int ty = y / gTileSize;
                        for (int tx = 0; tx < gTilesX; ++tx) {
                            int startX = tx * gTileSize;
                            if (startX >= copyWRO)
                                break;
                            int endX = startX + gTileSize;
                            if (endX > copyWRO)
                                endX = copyWRO;
                            size_t offset = (size_t)startX * (size_t)gBytesPerPixel;
                            size_t length = (size_t)(endX - startX) * (size_t)gBytesPerPixel;
                            size_t tileIndex = (size_t)ty * (size_t)gTilesX + (size_t)tx;
                            gCurrHash[tileIndex] =
                                fnv1a_update(gCurrHash[tileIndex], baseRO + (size_t)y * srcBPRRO + offset, length);
                        }
                    }
                    accumulatePendingDirty();
                    swapTileHashes();
                    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                }
                // When scaled, skip advancing hashes to avoid expensive work; we'll catch up on next frame.
                return;
            }

            CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
            const size_t srcBPR = (size_t)CVPixelBufferGetBytesPerRow(pb);
            const size_t width = (size_t)CVPixelBufferGetWidth(pb);
            const size_t height = (size_t)CVPixelBufferGetHeight(pb);

            if ((int)width != gWidth || (int)height != gHeight) {
                // With scaling enabled, this is expected; log once for info. Without scaling, warn once.
                static BOOL sLoggedSizeInfoOnce = NO;
                if (!sLoggedSizeInfoOnce) {
                    if (gScale != 1.0) {
                        TVLog(@"Scaling source %zux%zu -> output %dx%d (scale=%.3f)", width, height, gWidth, gHeight,
                              gScale);
                    } else {
                        TVLog(
                            @"Captured frame size %zux%zu differs from server %dx%d; cropping/copying minimum region.",
                            width, height, gWidth, gHeight);
                    }
                    sLoggedSizeInfoOnce = YES;
                }
            }

            // Copy/Scale into back buffer, then hash per tile
            resetCurrTileHashes();
            if (gScale == 1.0) {
                // Fast path: 1:1 copy + hash
                int copyW = MIN((int)width, gWidth);
                int copyH = MIN((int)height, gHeight);
                copyAndHashTiled((uint8_t *)gBackBuffer, base, copyW, copyH, srcBPR);
            } else {
                // vImage scaling path: scale source into tightly-packed back buffer (BGRA/ARGB8888)
                vImage_Buffer srcBuf;
                srcBuf.data = base;
                srcBuf.height = (vImagePixelCount)height;
                srcBuf.width = (vImagePixelCount)width;
                srcBuf.rowBytes = srcBPR;
                vImage_Buffer dstBuf;
                dstBuf.data = gBackBuffer;
                dstBuf.height = (vImagePixelCount)gHeight;
                dstBuf.width = (vImagePixelCount)gWidth;
                dstBuf.rowBytes = (size_t)gWidth * (size_t)gBytesPerPixel;
                vImage_Error err = vImageScale_ARGB8888(&srcBuf, &dstBuf, NULL, kvImageHighQualityResampling);
                if (err != kvImageNoError) {
                    static BOOL sLoggedVImageErrOnce = NO;
                    if (!sLoggedVImageErrOnce) {
                        TVLog(@"vImageScale_ARGB8888 failed: %ld", (long)err);
                        sLoggedVImageErrOnce = YES;
                    }
                    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                    return;
                }
                // Hash over the scaled back buffer
                hashTiledFromBuffer((const uint8_t *)gBackBuffer, gWidth, gHeight,
                                    (size_t)gWidth * (size_t)gBytesPerPixel);
            }
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

            // Build dirty rectangles with deferred coalescing window
            enum { kRectBuf = 1024 };
            DirtyRect rects[kRectBuf];
            int changedTiles = 0;

            // Accumulate pending dirty tiles
            accumulatePendingDirty();

            // Decide whether to flush now
            BOOL shouldFlush = YES;
            if (gDeferWindowSec > 0) {
                if (!gHasPending) {
                    gHasPending = YES;
                    gDeferStartTime = CFAbsoluteTimeGetCurrent();
                    shouldFlush = NO; // start window, wait for more
                } else {
                    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                    shouldFlush = ((now - gDeferStartTime) >= gDeferWindowSec);
                }
            }

            int rectCount = 0;
            int changedPct = 0;
            BOOL fullScreen = NO;
            if (shouldFlush) {
                // Promote pending tiles into rects
                rectCount = buildRectsFromPending(rects, MIN(gMaxRectsLimit, kRectBuf));
                // If anything from this frame is also new dirty not in pending, ensure included
                int extraTiles = 0;
                if (rectCount == 0) {
                    rectCount = buildDirtyRects(rects, MIN(gMaxRectsLimit, kRectBuf), &changedTiles);
                } else {
                    // Merge current frame dirties by re-running with hashes, bounded
                    DirtyRect rectsNow[kRectBuf];
                    int nowCount = buildDirtyRects(rectsNow, MIN(gMaxRectsLimit, kRectBuf), &extraTiles);
                    // Simple append then vertical merge will compact later in pipeline
                    int space = kRectBuf - rectCount;
                    int take = nowCount < space ? nowCount : space;
                    if (take > 0)
                        memcpy(&rects[rectCount], rectsNow, (size_t)take * sizeof(DirtyRect));
                    rectCount += take;
                }
                int totalTiles = (int)gTileCount;
                int totalChanged = changedTiles + extraTiles;
                changedPct = (totalTiles > 0) ? (totalChanged * 100 / totalTiles) : 100;
                if (rectCount >= gMaxRectsLimit) {
                    // Collapse to bounding box
                    int minX = gWidth, minY = gHeight, maxX = 0, maxY = 0;
                    for (int i = 0; i < rectCount; ++i) {
                        if (rects[i].w <= 0 || rects[i].h <= 0)
                            continue;
                        if (rects[i].x < minX)
                            minX = rects[i].x;
                        if (rects[i].y < minY)
                            minY = rects[i].y;
                        if (rects[i].x + rects[i].w > maxX)
                            maxX = rects[i].x + rects[i].w;
                        if (rects[i].y + rects[i].h > maxY)
                            maxY = rects[i].y + rects[i].h;
                    }
                    rects[0] = (DirtyRect){minX, minY, maxX - minX, maxY - minY};
                    rectCount = 1;
                }
                fullScreen = (changedPct >= gFullscreenThresholdPercent) || rectCount == 0;
                // Clear pending
                if (gPendingDirty)
                    memset(gPendingDirty, 0, gTileCount);
                gHasPending = NO;
            } else {
                // Still deferring: do not notify clients yet
                CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                swapTileHashes();
                return;
            }

            if (gAsyncSwapEnabled) {
                // Try non-blocking swap with fallback to single-buffer copy.
                pthread_mutex_t *locked[64];
                size_t lockedCount = 0;
                if (tryLockAllClients(locked, &lockedCount, sizeof(locked) / sizeof(locked[0]))) {
                    swapBuffers();
                    for (size_t i = 0; i < lockedCount; ++i)
                        pthread_mutex_unlock(locked[i]);
                    if (fullScreen) {
                        rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);
                    } else {
                        markRectsModified(rects, rectCount);
                    }
                } else {
                    if (fullScreen) {
                        // Whole screen copy fallback (tight -> tight)
                        copyWithStrideTight((uint8_t *)gFrontBuffer, (uint8_t *)gBackBuffer, gWidth, gHeight,
                                            (size_t)gWidth * (size_t)gBytesPerPixel);
                        rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);
                    } else {
                        // Only copy dirty regions from back to front to reduce tearing and bandwidth
                        copyRectsFromBackToFront(rects, rectCount);
                        markRectsModified(rects, rectCount);
                    }
                }
            } else {
                // Original blocking behavior to avoid tearing.
                lockAllClientsBlocking();
                swapBuffers();
                if (fullScreen) {
                    rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);
                } else {
                    markRectsModified(rects, rectCount);
                }
                unlockAllClientsBlocking();
            }

            // Prepare for next frame: current hashes become previous
            swapTileHashes();
        };

        TVLog(@"Screen capture is armed and will start when the first client connects.");
    }

    // Keep process alive: ScreenCapturer uses CADisplayLink on main run loop.
    CFRunLoopRun();
    return 0;
}

// MARK: - Signals / Shutdown

static void handleSignal(int signum) {
    (void)signum;
    gShouldTerminate = 1;
    // Best-effort: stop runloop to unwind main and allow cleanup.
    CFRunLoopStop(CFRunLoopGetMain());
}

static void installSignalHandlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handleSignal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

__attribute__((unused)) static void cleanupAndExit(int code) {
    if (gScreen) {
        rfbScreenCleanup(gScreen);
        gScreen = NULL;
    }
    if (gFrontBuffer) {
        free(gFrontBuffer);
        gFrontBuffer = NULL;
    }
    if (gBackBuffer) {
        free(gBackBuffer);
        gBackBuffer = NULL;
    }
    if (gPrevHash) {
        free(gPrevHash);
        gPrevHash = NULL;
    }
    if (gCurrHash) {
        free(gCurrHash);
        gCurrHash = NULL;
    }
    exit(code);
}
