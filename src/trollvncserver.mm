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

#import <rfb/keysym.h>
#import <rfb/rfb.h>

#import <errno.h>
#import <signal.h>
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

// Forward declarations
static void installSignalHandlers(void);
static void handleSignal(int signum);
static void cleanupAndExit(int code);

// MARK: - Helpers

static void lockAllClients(void) {
    rfbClientIteratorPtr it = rfbGetClientIterator(gScreen);
    rfbClientPtr cl;
    while ((cl = rfbClientIteratorNext(it))) {
        LOCK(cl->sendMutex);
    }
    rfbReleaseClientIterator(it);
}

static void unlockAllClients(void) {
    rfbClientIteratorPtr it = rfbGetClientIterator(gScreen);
    rfbClientPtr cl;
    while ((cl = rfbClientIteratorNext(it))) {
        UNLOCK(cl->sendMutex);
    }
    rfbReleaseClientIterator(it);
}

static void swapBuffers(void) {
    void *tmp = gFrontBuffer;
    gFrontBuffer = gBackBuffer;
    gBackBuffer = tmp;
    gScreen->frameBuffer = (char *)gFrontBuffer;
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

// MARK: - CLI

static void printUsageAndExit(const char *prog) {
    fprintf(stderr, "Usage: %s [-p port] [-n name] [-v] [-h]\n", prog);
    fprintf(stderr, "  -p port   TCP port for VNC (default: %d)\n", gPort);
    fprintf(stderr, "  -n name   Desktop name shown to clients (default: %s)\n", [gDesktopName UTF8String]);
    fprintf(stderr, "  -v        View-only (ignore input)\n");
    fprintf(stderr, "  -h        Show help\n\n");
    rfbUsage();
    exit(EXIT_SUCCESS);
}

static void parseCLI(int argc, const char *argv[]) {
    int opt;
    while ((opt = getopt(argc, (char *const *)argv, "p:n:vh")) != -1) {
        switch (opt) {
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
        gWidth = [props[(__bridge NSString *)kIOSurfaceWidth] intValue];
        gHeight = [props[(__bridge NSString *)kIOSurfaceHeight] intValue];
        if (gWidth <= 0 || gHeight <= 0) {
            fprintf(stderr, "Failed to resolve screen size from ScreenCapturer properties.\n");
            return EXIT_FAILURE;
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

        // In this step we don’t expose input handlers; honor viewOnly at the client level.
        gScreen->ptrAddEvent = NULL;
        gScreen->kbdAddEvent = NULL;

        // Cursor: we capture the cursor in the framebuffer already.
        gScreen->cursor = NULL;

        rfbInitServer(gScreen);
        TVLog(@"VNC server initialized on port %d, %dx%d, name '%@'", gPort, gWidth, gHeight, gDesktopName);

        // Run VNC in background thread
        rfbRunEventLoop(gScreen, -1, TRUE);

        // 5) Install signal handlers for graceful shutdown
        installSignalHandlers();

        // 6) Prepare screen capture, but DO NOT start yet; start on first client connect
        gCapturer = [ScreenCapturer sharedCapturer];
        gFrameHandler = ^(CMSampleBufferRef _Nonnull sampleBuffer) {
            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (!pb)
                return;

            CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
            const size_t srcBPR = (size_t)CVPixelBufferGetBytesPerRow(pb);
            const size_t width = (size_t)CVPixelBufferGetWidth(pb);
            const size_t height = (size_t)CVPixelBufferGetHeight(pb);

            if ((int)width != gWidth || (int)height != gHeight) {
                // Dimension mismatch should not happen; log once per occurrence.
                TVLog(@"Captured frame size %zux%zu differs from server %dx%d; cropping/copying minimum region.", width,
                      height, gWidth, gHeight);
            }

            // Copy into our tight back buffer, respecting capture stride.
            copyWithStrideTight((uint8_t *)gBackBuffer, base, MIN((int)width, gWidth), MIN((int)height, gHeight),
                                srcBPR);
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

            // Swap buffers under client sendMutex to avoid tearing.
            lockAllClients();
            swapBuffers();

            // Mark whole screen modified; later we can optimize to dirty rects.
            rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);
            unlockAllClients();
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
    exit(code);
}
