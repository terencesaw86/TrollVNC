/*
 This file is part of TrollVNC
 Copyright (c) 2025 82flex and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import <Accelerate/Accelerate.h>
#import <Foundation/Foundation.h>

#import <atomic>
#import <cstdlib>
#import <cstring>
#import <mach-o/dyld.h>
#import <rfb/keysym.h>
#import <rfb/rfb.h>
#import <string>

#import "ClipboardManager.h"
#import "FBSOrientationObserver.h"
#import "IOKitSPI.h"
#import "STHIDEventGenerator.h"
#import "ScreenCapturer.h"

#if DEBUG
#define TVLog(fmt, ...) NSLog((@"%s:%d " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__)
#else
#define TVLog(...)
#endif

#if FB_DEBUG
#define FBLog(fmt, ...) NSLog((@"%s:%d FB: " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__)
#else
#define FBLog(...)
#endif

#pragma mark - Options

static int gPort = 5901;
static NSString *gDesktopName = @"TrollVNC";
static BOOL gViewOnly = NO;
static double gKeepAliveSec = 0.0; // 15..86400
static BOOL gClipboardEnabled = YES;

static double gScale = 1.0; // 0 < scale <= 1.0, 1.0 = no scaling
// Preferred frame rate range (0 = unspecified)
static int gFpsMin = 0;
static int gFpsPref = 0;
static int gFpsMax = 0;
static double gDeferWindowSec = 0.015;      // Coalescing window; 0 disables deferral
static int gMaxInflightUpdates = 2;         // Max concurrent client encodes; drop frames if >= this
static int gTileSize = 32;                  // Tile size for dirty detection (pixels)
static int gFullscreenThresholdPercent = 0; // If changed tiles exceed this %, update full screen
static int gMaxRectsLimit = 256;            // Max rects before falling back to bbox/fullscreen
static BOOL gAsyncSwapEnabled = NO;         // Enable non-blocking swap (may cause tearing)

// Wheel scroll coalescing state (async, non-blocking)
static double gWheelStepPx = 48.0;        // base pixels per wheel tick (lower = slower)
static double gWheelMaxStepPx = 192.0;    // base max distance per flush (pre-clamp)
static double gWheelCoalesceSec = 0.03;   // coalescing window
static double gWheelAbsClampFactor = 2.5; // absolute clamp = factor * gWheelMaxStepPx
static double gWheelAmpCoeff = 0.18;      // velocity amplification coefficient
static double gWheelAmpCap = 0.75;        // max extra amplification (0..1)
static double gWheelMinTakeRatio = 0.35;  // minimum take distance vs step size
static double gWheelDurBase = 0.05;       // duration base seconds
static double gWheelDurK = 0.00016;       // duration factor applied to sqrt(distance)
static double gWheelDurMin = 0.05;        // duration clamp min
static double gWheelDurMax = 0.14;        // duration clamp max
static BOOL gWheelNaturalDir = NO;        // natural scroll direction (invert delta)

// Modifier mapping scheme: 0 = standard (Alt->Option, Meta/Super->Command), 1 = Alt-as-Command
static int gModMapScheme = 0;
static BOOL gKeyEventLogging = NO;
static BOOL gCursorEnabled = NO;
static BOOL gOrientationSyncEnabled = NO;

// Classic VNC authentication
static char **gAuthPasswdVec = NULL;        // owns the vector
static char *gAuthPasswdStr = NULL;         // owns the duplicated password string
static char *gAuthViewOnlyPasswdStr = NULL; // optional view-only password string

// HTTP server (LibVNCServer built-in web client)
static int gHttpPort = 0;
static char *gHttpDirOverride = NULL;
static char *gSslCertPath = NULL;
static char *gSslKeyPath = NULL;

static void printUsageAndExit(const char *prog) {
    // Compact, grouped usage for quick reference. See README for detailed explanations.
    fprintf(stderr, "Usage: %s [-p port] [-n name] [options]\n\n", prog);

    fprintf(stderr, "Basic:\n");
    fprintf(stderr, "  -p port   VNC TCP port (default: %d)\n", gPort);
    fprintf(stderr, "  -n name   Desktop name (default: %s)\n", [gDesktopName UTF8String]);
    fprintf(stderr, "  -v        View-only (ignore input)\n");
    fprintf(stderr, "  -A sec    Keep-alive interval to prevent sleep; only when clients > 0 (15..86400, 0=off)\n");
    fprintf(stderr, "  -C on|off Clipboard sync (default: on)\n\n");

    fprintf(stderr, "Display/Perf:\n");
    fprintf(stderr, "  -s scale  Output scale 0<s<=1 (default: %.2f)\n", gScale);
    fprintf(stderr, "  -F spec   Frame rate: fps | min-max | min:pref:max\n");
    fprintf(stderr, "  -d sec    Defer window (0..0.5, default: %.3f)\n", gDeferWindowSec);
    fprintf(stderr, "  -Q n      Max in-flight encodes (0=never drop, default: %d)\n\n", gMaxInflightUpdates);

    fprintf(stderr, "Dirty detection:\n");
    fprintf(stderr, "  -t size   Tile size (8..128, default: %d)\n", gTileSize);
    fprintf(stderr, "  -P pct    Fullscreen fallback threshold (0..100; 0=disable dirty detection, default: %d)\n",
            gFullscreenThresholdPercent);
    fprintf(stderr, "  -R max    Max dirty rects before bbox (default: %d)\n", gMaxRectsLimit);
    fprintf(stderr, "  -a        Non-blocking swap (may cause tearing)\n\n");

    fprintf(stderr, "Scroll/Input:\n");
    fprintf(stderr, "  -W px     Wheel step in pixels (0=disable, default: %.0f)\n", gWheelStepPx);
    fprintf(stderr,
            "  -w k=v,.. Wheel tuning keys: step,coalesce,max,clamp,amp,cap,minratio,durbase,durk,durmin,durmax\n");
    fprintf(stderr, "  -N        Natural scroll direction (invert wheel)\n");
    fprintf(stderr, "  -M scheme Modifier mapping: std|altcmd (default: std)\n");
    fprintf(stderr, "  -K        Log keyboard events to stderr\n\n");

    fprintf(stderr, "Cursor:\n");
    fprintf(stderr, "  -U on|off Enable server-side cursor X (default: off)\n\n");

    fprintf(stderr, "Rotate/Orientation:\n");
    fprintf(stderr, "  -O on|off Observe iOS interface orientation and sync (default: off)\n\n");

    fprintf(stderr, "HTTP/WebSockets:\n");
    fprintf(stderr, "  -H port   Enable built-in HTTP server on port (0=off, default: 0)\n");
    fprintf(stderr, "  -D path   Absolute path for HTTP document root\n");
    fprintf(stderr, "  -e file   Path to SSL certificate file\n");
    fprintf(stderr, "  -k file   Path to SSL private key file\n\n");

    fprintf(stderr, "Help:\n");
    fprintf(stderr, "  -h        Show this help message\n\n");

    fprintf(stderr, "Environment:\n");
    fprintf(stderr,
            "  TROLLVNC_PASSWORD           Classic VNC password (enables VNC auth when set; first 8 chars used)\n");
    fprintf(stderr,
            "  TROLLVNC_VIEWONLY_PASSWORD  View-only password; passwords stored as [full..., view-only...]\n\n");

    exit(EXIT_SUCCESS);
}

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
            TVLog(@"Wheel tuning: step=%g", gWheelStepPx);
        } else if (strcmp(key, "coalesce") == 0) {
            if (d >= 0 && d <= 0.5)
                gWheelCoalesceSec = d;
            TVLog(@"Wheel tuning: coalesce=%g", gWheelCoalesceSec);
        } else if (strcmp(key, "max") == 0) {
            if (d > 0)
                gWheelMaxStepPx = d;
            TVLog(@"Wheel tuning: max=%g", gWheelMaxStepPx);
        } else if (strcmp(key, "clamp") == 0) {
            if (d >= 1.0 && d <= 10.0)
                gWheelAbsClampFactor = d;
            TVLog(@"Wheel tuning: clamp=%g", gWheelAbsClampFactor);
        } else if (strcmp(key, "amp") == 0) {
            if (d >= 0.0 && d <= 5.0)
                gWheelAmpCoeff = d;
            TVLog(@"Wheel tuning: amp=%g", gWheelAmpCoeff);
        } else if (strcmp(key, "cap") == 0) {
            if (d >= 0.0 && d <= 2.0)
                gWheelAmpCap = d;
            TVLog(@"Wheel tuning: cap=%g", gWheelAmpCap);
        } else if (strcmp(key, "minratio") == 0) {
            if (d >= 0.0 && d <= 2.0)
                gWheelMinTakeRatio = d;
            TVLog(@"Wheel tuning: minratio=%g", gWheelMinTakeRatio);
        } else if (strcmp(key, "durbase") == 0) {
            if (d >= 0.0 && d <= 1.0)
                gWheelDurBase = d;
            TVLog(@"Wheel tuning: durbase=%g", gWheelDurBase);
        } else if (strcmp(key, "durk") == 0) {
            if (d >= 0.0 && d <= 1.0)
                gWheelDurK = d;
            TVLog(@"Wheel tuning: durk=%g", gWheelDurK);
        } else if (strcmp(key, "durmin") == 0) {
            if (d >= 0.0 && d <= 1.0)
                gWheelDurMin = d;
            TVLog(@"Wheel tuning: durmin=%g", gWheelDurMin);
        } else if (strcmp(key, "durmax") == 0) {
            if (d >= 0.0 && d <= 2.0)
                gWheelDurMax = d;
            TVLog(@"Wheel tuning: durmax=%g", gWheelDurMax);
        } else if (strcmp(key, "natural") == 0) {
            gWheelNaturalDir = (d != 0.0);
            TVLog(@"Wheel tuning: natural=%@", gWheelNaturalDir ? @"YES" : @"NO");
        }
    }
    free(dup);
}

static void parseCLI(int argc, const char *argv[]) {
    int opt;
    const char *optstr = "p:n:vA:C:s:F:d:Q:t:P:R:aW:w:NM:KU:O:H:D:e:k:h";
    while ((opt = getopt(argc, (char *const *)argv, optstr)) != -1) {
        switch (opt) {
        case 'p': {
            long port = strtol(optarg, NULL, 10);
            if (port <= 0 || port > 65535) {
                fprintf(stderr, "Invalid port: %s\n", optarg);
                exit(EXIT_FAILURE);
            }
            gPort = (int)port;
            TVLog(@"CLI: Port set to %d", gPort);
            break;
        }
        case 'n': {
            gDesktopName = [NSString stringWithUTF8String:optarg ?: "TrollVNC"];
            TVLog(@"CLI: Desktop name set to '%@'", gDesktopName);
            break;
        }
        case 'v': {
            gViewOnly = YES;
            TVLog(@"CLI: View-only mode enabled (-v)");
            break;
        }
        case 'A': {
            double sec = strtod(optarg ? optarg : "0", NULL);
            if (sec < 15.0 || sec > 24 * 3600.0) {
                fprintf(stderr, "Invalid keep-alive seconds: %s (expected 15..86400)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gKeepAliveSec = sec;
            TVLog(@"CLI: KeepAlive interval set to %.3f sec (-A)", gKeepAliveSec);
            break;
        }
        case 'C': {
            const char *val = optarg ? optarg : "on";
            if (strcasecmp(val, "on") == 0 || strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0) {
                gClipboardEnabled = YES;
                TVLog(@"CLI: Clipboard sync enabled (-C %s)", [@(val) UTF8String]);
            } else if (strcasecmp(val, "off") == 0 || strcmp(val, "0") == 0 || strcasecmp(val, "false") == 0) {
                gClipboardEnabled = NO;
                TVLog(@"CLI: Clipboard sync disabled (-C %s)", [@(val) UTF8String]);
            } else {
                fprintf(stderr, "Invalid -C value: %s (expected on|off|1|0|true|false)\n", val);
                exit(EXIT_FAILURE);
            }
            break;
        }
        case 's': {
            double sc = strtod(optarg, NULL);
            if (!(sc > 0.0 && sc <= 1.0)) {
                fprintf(stderr, "Invalid scale: %s (expected 0 < s <= 1)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gScale = sc;
            TVLog(@"CLI: Output scale factor set to %.3f", gScale);
            break;
        }
        case 'F': {
            // Accept formats: "fps", "min-max", "min:pref:max"
            const char *spec = optarg ? optarg : "";
            int minV = 0, prefV = 0, maxV = 0;
            if (spec[0] == '\0') {
                break; // ignore empty
            }
            const char *colon1 = strchr(spec, ':');
            const char *dash = strchr(spec, '-');
            if (colon1) {
                // min:pref:max
                long a = strtol(spec, NULL, 10);
                const char *p2 = colon1 + 1;
                const char *colon2 = strchr(p2, ':');
                if (!colon2) {
                    fprintf(stderr, "Invalid -F spec: %s (expected min:pref:max)\n", spec);
                    exit(EXIT_FAILURE);
                }
                long b = strtol(p2, NULL, 10);
                long c = strtol(colon2 + 1, NULL, 10);
                minV = (int)a;
                prefV = (int)b;
                maxV = (int)c;
            } else if (dash) {
                // min-max (preferred defaults to max)
                long a = strtol(spec, NULL, 10);
                long b = strtol(dash + 1, NULL, 10);
                minV = (int)a;
                prefV = (int)b;
                maxV = (int)b;
            } else {
                // single fps
                long v = strtol(spec, NULL, 10);
                minV = (int)v;
                prefV = (int)v;
                maxV = (int)v;
            }
            // Normalize & validate: allow 0..240 (0 = unspecified)
            if (minV < 0)
                minV = 0;
            if (minV > 240)
                minV = 240;
            if (prefV < 0)
                prefV = 0;
            if (prefV > 240)
                prefV = 240;
            if (maxV < 0)
                maxV = 0;
            if (maxV > 240)
                maxV = 240;
            if (minV > 0 && maxV > 0 && minV > maxV) {
                int tmp = minV;
                minV = maxV;
                maxV = tmp;
            }
            if (prefV > 0) {
                if (minV > 0 && prefV < minV)
                    prefV = minV;
                if (maxV > 0 && prefV > maxV)
                    prefV = maxV;
            }
            gFpsMin = minV;
            gFpsPref = prefV;
            gFpsMax = maxV;
            TVLog(@"CLI: FPS preference set to min=%d pref=%d max=%d", gFpsMin, gFpsPref, gFpsMax);
            break;
        }
        case 'd': {
            double s = strtod(optarg, NULL);
            if (s < 0.0 || s > 0.5) {
                fprintf(stderr, "Invalid defer window seconds: %s (expected 0..0.5)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gDeferWindowSec = s;
            TVLog(@"CLI: Defer window set to %.3f sec", gDeferWindowSec);
            break;
        }
        case 'Q': {
            long q = strtol(optarg, NULL, 10);
            if (q < 0 || q > 8) {
                fprintf(stderr, "Invalid max in-flight: %s (expected 0..8)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gMaxInflightUpdates = (int)q;
            TVLog(@"CLI: Max in-flight updates set to %d", gMaxInflightUpdates);
            break;
        }
        case 't': {
            long ts = strtol(optarg, NULL, 10);
            if (ts < 8 || ts > 128) {
                fprintf(stderr, "Invalid tile size: %s (expected 8..128)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gTileSize = (int)ts;
            TVLog(@"CLI: Tile size set to %d", gTileSize);
            break;
        }
        case 'P': {
            long p = strtol(optarg, NULL, 10);
            if (p < 0 || p > 100) {
                fprintf(stderr, "Invalid threshold percent: %s (expected 0..100; 0 disables dirty detection)\n",
                        optarg);
                exit(EXIT_FAILURE);
            }
            gFullscreenThresholdPercent = (int)p;
            TVLog(@"CLI: Fullscreen threshold percent set to %d", gFullscreenThresholdPercent);
            break;
        }
        case 'R': {
            long m = strtol(optarg, NULL, 10);
            if (m < 1 || m > 4096) {
                fprintf(stderr, "Invalid max rects: %s (expected 1..4096)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gMaxRectsLimit = (int)m;
            TVLog(@"CLI: Max rects limit set to %d", gMaxRectsLimit);
            break;
        }
        case 'a': {
            gAsyncSwapEnabled = YES;
            TVLog(@"CLI: Non-blocking swap enabled (-a)");
            break;
        }
        case 'W': {
            double px = strtod(optarg, NULL);
            if (px == 0.0) {
                // 0 disables wheel emulation
                gWheelStepPx = 0.0;
                gWheelMaxStepPx = 0.0;
                TVLog(@"CLI: Wheel emulation disabled (-W 0)");
                break;
            }
            if (!(px > 4.0 && px <= 1000.0)) {
                fprintf(stderr, "Invalid wheel step px: %s (expected 0 or >4..<=1000)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gWheelStepPx = px;
            // Scale max step roughly 4x and adjust duration slope mildly
            gWheelMaxStepPx = fmax(2.0 * gWheelStepPx, 96.0) * 1.0;
            TVLog(@"CLI: Wheel step set to %.1f px (max=%.1f)", gWheelStepPx, gWheelMaxStepPx);
            break;
        }
        case 'w': {
            parseWheelOptions(optarg);
            break;
        }
        case 'N': {
            gWheelNaturalDir = YES;
            TVLog(@"CLI: Natural scroll direction enabled (-N)");
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
            TVLog(@"CLI: Modifier mapping set to %s", gModMapScheme == 0 ? "std" : "altcmd");
            break;
        }
        case 'K': {
            gKeyEventLogging = YES;
            TVLog(@"CLI: Keyboard event logging enabled (-K)");
            break;
        }
        case 'U': {
            const char *val = optarg ? optarg : "off";
            if (strcasecmp(val, "on") == 0 || strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0) {
                gCursorEnabled = YES;
                TVLog(@"CLI: Cursor enabled (-U %s)", [@(val) UTF8String]);
            } else if (strcasecmp(val, "off") == 0 || strcmp(val, "0") == 0 || strcasecmp(val, "false") == 0) {
                gCursorEnabled = NO;
                TVLog(@"CLI: Cursor disabled (-U %s)", [@(val) UTF8String]);
            } else {
                fprintf(stderr, "Invalid -U value: %s (expected on|off|1|0|true|false)\n", val);
                exit(EXIT_FAILURE);
            }
            break;
        }
        case 'O': {
            const char *val = optarg ? optarg : "off";
            if (strcasecmp(val, "on") == 0 || strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0) {
                gOrientationSyncEnabled = YES;
                TVLog(@"CLI: Orientation observer enabled (-O %s)", [@(val) UTF8String]);
            } else if (strcasecmp(val, "off") == 0 || strcmp(val, "0") == 0 || strcasecmp(val, "false") == 0) {
                gOrientationSyncEnabled = NO;
                TVLog(@"CLI: Orientation observer disabled (-O %s)", [@(val) UTF8String]);
            } else {
                fprintf(stderr, "Invalid -O value: %s (expected on|off|1|0|true|false)\n", val);
                exit(EXIT_FAILURE);
            }
            break;
        }
        case 'H': {
            long hp = strtol(optarg ? optarg : "0", NULL, 10);
            if (hp < 0 || hp > 65535) {
                fprintf(stderr, "Invalid HTTP port: %s (expected 0..65535)\n", optarg);
                exit(EXIT_FAILURE);
            }
            gHttpPort = (int)hp;
            TVLog(@"CLI: HTTP port set to %d (-H)", gHttpPort);
            break;
        }
        case 'D': {
            const char *path = optarg ? optarg : "";
            if (!path || path[0] != '/') {
                fprintf(stderr, "Invalid httpDir path for -D: %s (must be absolute)\n", path);
                exit(EXIT_FAILURE);
            }
            if (gHttpDirOverride) {
                free(gHttpDirOverride);
                gHttpDirOverride = NULL;
            }
            gHttpDirOverride = strdup(path);
            if (!gHttpDirOverride) {
                fprintf(stderr, "Failed to duplicate httpDir path\n");
                exit(EXIT_FAILURE);
            }
            TVLog(@"CLI: HTTP dir override set to %s (-D)", path);
            break;
        }
        case 'e': {
            const char *path = optarg ? optarg : "";
            if (!path || !*path) {
                fprintf(stderr, "Invalid value for -e (sslcertfile)\n");
                exit(EXIT_FAILURE);
            }
            if (gSslCertPath) {
                free(gSslCertPath);
                gSslCertPath = NULL;
            }
            gSslCertPath = strdup(path);
            if (!gSslCertPath) {
                fprintf(stderr, "Failed to duplicate sslcertfile path\n");
                exit(EXIT_FAILURE);
            }
            TVLog(@"CLI: SSL cert file set (-e %s)", path);
            break;
        }
        case 'k': {
            const char *path = optarg ? optarg : "";
            if (!path || !*path) {
                fprintf(stderr, "Invalid value for -k (sslkeyfile)\n");
                exit(EXIT_FAILURE);
            }
            if (gSslKeyPath) {
                free(gSslKeyPath);
                gSslKeyPath = NULL;
            }
            gSslKeyPath = strdup(path);
            if (!gSslKeyPath) {
                fprintf(stderr, "Failed to duplicate sslkeyfile path\n");
                exit(EXIT_FAILURE);
            }
            TVLog(@"CLI: SSL key file set (-k %s)", path);
            break;
        }
        case 'h':
        default: {
            printUsageAndExit(argv[0]);
            break;
        }
        }
    }
}

#pragma mark - Display

static rfbScreenInfoPtr gScreen = NULL;
static void (^gFrameHandler)(CMSampleBufferRef) = nil;

static int gWidth = 0;
static int gHeight = 0;
static int gSrcWidth = 0;      // capture source width
static int gSrcHeight = 0;     // capture source height
static size_t gFBSize = 0;     // in bytes
static int gBytesPerPixel = 4; // ARGB/BGRA 32-bit

static void *gFrontBuffer = NULL; // Exposed to VNC clients via gScreen->frameBuffer
static void *gBackBuffer = NULL;  // We render into this and then swap

// Hash algorithm selection (auto: prefer CRC32 on ARM with hardware support)
#if FB_LOG
#if defined(__aarch64__) || defined(__ARM_FEATURE_CRC32)
static const BOOL gUseCRC32Hash = YES;
#else
static const BOOL gUseCRC32Hash = NO;
#endif
#endif

typedef struct {
    int x, y, w, h;
} DirtyRect;

#if defined(__aarch64__) || defined(__ARM_FEATURE_CRC32)
NS_INLINE uint64_t crc32_update(uint64_t h, const uint8_t *data, size_t len) {
    uint32_t c = (uint32_t)h;
    const uint8_t *p = data;
    size_t n = len;
    // Process 8-byte chunks
    while (n >= 8) {
        uint64_t v;
        // Unaligned load is acceptable on ARM64; use memcpy to be safe for strict aliasing.
        memcpy(&v, p, sizeof(v));
        c = __builtin_arm_crc32d(c, v);
        p += 8;
        n -= 8;
    }
    if (n >= 4) {
        uint32_t v32;
        memcpy(&v32, p, sizeof(v32));
        c = __builtin_arm_crc32w(c, v32);
        p += 4;
        n -= 4;
    }
    if (n >= 2) {
        uint16_t v16;
        memcpy(&v16, p, sizeof(v16));
        c = __builtin_arm_crc32h(c, v16);
        p += 2;
        n -= 2;
    }
    if (n) {
        c = __builtin_arm_crc32b(c, *p);
    }
    return (uint64_t)c;
}
#else
NS_INLINE uint64_t fnv1a_basis(void) { return 1469598103934665603ULL; }
NS_INLINE uint64_t fnv1a_update(uint64_t h, const uint8_t *data, size_t len) {
    const uint64_t FNV_PRIME = 1099511628211ULL;
    for (size_t i = 0; i < len; ++i) {
        h ^= (uint64_t)data[i];
        h *= FNV_PRIME;
    }
    return h;
}
#endif

// Generic hash wrappers: prefer hardware CRC32 when enabled and available, else fallback to FNV-1a.
NS_INLINE uint64_t hash_basis(void) {
#if defined(__aarch64__) || defined(__ARM_FEATURE_CRC32)
    return 0u; // CRC32 initial accumulator
#else
    return fnv1a_basis();
#endif
}

NS_INLINE uint64_t hash_update(uint64_t h, const uint8_t *data, size_t len) {
#if defined(__aarch64__) || defined(__ARM_FEATURE_CRC32)
    return crc32_update(h, data, len);
#else
    // If CRC32 not supported at compile time, fallback to FNV-1a
    return fnv1a_update(h, data, len);
#endif
}

#pragma mark - Display Tiling

static int gTilesX = 0;
static int gTilesY = 0;
static size_t gTileCount = 0;
static uint64_t *gPrevHash = NULL;
static uint64_t *gCurrHash = NULL;
static uint8_t *gPendingDirty = NULL; // per-tile pending dirty mask
static BOOL gHasPending = NO;

static void initializeTilingOrReset(void) {
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
            fprintf(stderr, "Out of memory for tile hashes\n");
            exit(EXIT_FAILURE);
        }

        for (size_t i = 0; i < tileCount; ++i) {
            gPrevHash[i] = 0; // force full update first frame
            gCurrHash[i] = hash_basis();
        }

        gTilesX = tilesX;
        gTilesY = tilesY;
        gTileCount = tileCount;

        if (gPendingDirty)
            memset(gPendingDirty, 0, gTileCount);
    } else {
        for (size_t i = 0; i < gTileCount; ++i) {
            gCurrHash[i] = hash_basis();
        }
    }
}

NS_INLINE void swapTileHashes(void) {
    uint64_t *tmp = gPrevHash;
    gPrevHash = gCurrHash;
    gCurrHash = tmp;
}

NS_INLINE void resetCurrTileHashes(void) {
    if (!gCurrHash || gTileCount == 0)
        return;
    uint64_t basis = hash_basis();
    for (size_t i = 0; i < gTileCount; ++i) {
        gCurrHash[i] = basis;
    }
}

// Accumulate pending dirty tiles for time-based coalescing
NS_INLINE void accumulatePendingDirty(void) {
    if (!gPendingDirty)
        return;

    for (size_t i = 0; i < gTileCount; ++i) {
        if (gCurrHash[i] != gPrevHash[i])
            gPendingDirty[i] = 1;
    }
}

NS_INLINE void hashTiledFromBuffer(const uint8_t *buf, int width, int height, size_t bpr) {
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
            gCurrHash[tileIndex] = hash_update(gCurrHash[tileIndex], buf + (size_t)y * bpr + offset, length);
        }
    }
}

// Sparse sampling hash: sample a subset of pixels per tile to reduce bandwidth.
NS_INLINE void hashTiledFromBufferSparse(const uint8_t *buf, int width, int height, size_t bpr, int sx, int sy) {
    if (sx < 1)
        sx = 1;
    if (sy < 1)
        sy = 1;
    resetCurrTileHashes();
    for (int y = 0; y < height; y += sy) {
        int ty = y / gTileSize;
        for (int tx = 0; tx < gTilesX; ++tx) {
            int startX = tx * gTileSize;
            if (startX >= width)
                break;
            int endX = startX + gTileSize;
            if (endX > width)
                endX = width;
            size_t tileIndex = (size_t)ty * (size_t)gTilesX + (size_t)tx;
            for (int x = startX; x < endX; x += sx) {
                const uint8_t *p = buf + (size_t)y * bpr + (size_t)x * (size_t)gBytesPerPixel;
                gCurrHash[tileIndex] = hash_update(gCurrHash[tileIndex], p, (size_t)gBytesPerPixel);
            }
            // Ensure last column contributes even if not aligned to stride
            int lastX = endX - 1;
            if (lastX >= startX && ((endX - startX - 1) % sx) != 0) {
                const uint8_t *p = buf + (size_t)y * bpr + (size_t)lastX * (size_t)gBytesPerPixel;
                gCurrHash[tileIndex] = hash_update(gCurrHash[tileIndex], p, (size_t)gBytesPerPixel);
            }
        }
    }
    // Also sample the last row if height-1 isn't covered by the stride
    int lastY = height - 1;
    if (lastY >= 0 && ((height - 1) % sy) != 0) {
        int ty = lastY / gTileSize;
        for (int tx = 0; tx < gTilesX; ++tx) {
            int startX = tx * gTileSize;
            if (startX >= width)
                break;
            int endX = startX + gTileSize;
            if (endX > width)
                endX = width;
            size_t tileIndex = (size_t)ty * (size_t)gTilesX + (size_t)tx;
            for (int x = startX; x < endX; x += sx) {
                const uint8_t *p = buf + (size_t)lastY * bpr + (size_t)x * (size_t)gBytesPerPixel;
                gCurrHash[tileIndex] = hash_update(gCurrHash[tileIndex], p, (size_t)gBytesPerPixel);
            }
            int lastX = endX - 1;
            if (lastX >= startX && ((endX - startX - 1) % sx) != 0) {
                const uint8_t *p = buf + (size_t)lastY * bpr + (size_t)lastX * (size_t)gBytesPerPixel;
                gCurrHash[tileIndex] = hash_update(gCurrHash[tileIndex], p, (size_t)gBytesPerPixel);
            }
        }
    }
}

// Parallel full hash over tiles: split by tile rows to reduce wall clock at flush.
NS_INLINE void hashTiledFromBufferParallel(const uint8_t *buf, int width, int height, size_t bpr, int threads) {
    if (threads <= 1) {
        hashTiledFromBuffer(buf, width, height, bpr);
        return;
    }
    resetCurrTileHashes();
    // Split by tile row bands
    int tilesY = gTilesY;
    if (tilesY <= 0)
        return;
    int bands = threads;
    if (bands > tilesY)
        bands = tilesY;
    dispatch_group_t grp = dispatch_group_create();
    for (int band = 0; band < bands; ++band) {
        dispatch_group_async(grp, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            for (int ty = band; ty < tilesY; ty += bands) {
                int startY = ty * gTileSize;
                int endY = startY + gTileSize;
                if (startY >= height)
                    break;
                if (endY > height)
                    endY = height;
                for (int y = startY; y < endY; ++y) {
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
                        // Each tileIndex is updated by a single band (fixed ty), no race across bands.
                        gCurrHash[tileIndex] =
                            hash_update(gCurrHash[tileIndex], buf + (size_t)y * bpr + offset, length);
                    }
                }
            }
        });
    }
    dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);
}

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

NS_INLINE void markRectsModified(DirtyRect *rects, int rectCount) {
    for (int i = 0; i < rectCount; ++i) {
        rfbMarkRectAsModified(gScreen, rects[i].x, rects[i].y, rects[i].x + rects[i].w, rects[i].y + rects[i].h);
    }
}

NS_INLINE void copyRectsFromBackToFront(DirtyRect *rects, int rectCount) {
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

#pragma mark - Display Hooks

static std::atomic<int> gInflight(0);

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

#pragma mark - Display Tiling Constants

// Hashing performance controls
static const int gHashStrideX = 4;              // sparse sampling stride X (>=1; 1 = full scan)
static const int gHashStrideY = 4;              // sparse sampling stride Y (>=1; 1 = full scan)
static const BOOL gSparseHashDuringDefer = YES; // use sparse hashing while within defer window
// Skip vImage scaling when src/dst size difference is small; copy with pad/crop instead
static const int gNoScalePadThresholdPx = 8; // if both |dW| and |dH| <= this, do pad/crop copy

// Flush-time hashing optimization
static const BOOL gParallelHashOnFlush = YES; // use parallel hashing at flush to reduce wall time

#pragma mark - Frame Handler

static std::atomic<int> gRotationQuad(0); // 0=0°, 1=90°, 2=180°, 3=270° (clockwise)
static void *gRotateScratch = NULL;       // rotation scratch (for 90°/270°)
static size_t gRotateScratchSize = 0;     // bytes
static void *gScaleTemp = NULL;           // vImage scale temp buffer
static size_t gScaleTempSize = 0;         // bytes

// Align width up to a multiple of 4 (helps encoders/clients). Preserve aspect by adjusting height.
NS_INLINE void alignDimensions(int rawW, int rawH, int *alignedW, int *alignedH) {
    if (rawW <= 0)
        rawW = 1;
    if (rawH <= 0)
        rawH = 1;
    // Round width up to next multiple of 4
    int w4 = (rawW + 3) & ~3;
    long long numer = (long long)rawH * (long long)w4;
    int hAdj = (int)((numer + rawW / 2) / rawW); // rounded to nearest
    if (hAdj <= 0)
        hAdj = 1;
    *alignedW = w4;
    *alignedH = hAdj;
}

// Resize framebuffer according to rotation (0/180 keep WxH from src, 90/270 swap), then apply scale
NS_INLINE void maybeResizeFramebufferForRotation(int rotQ) {
    // Source capture size (portrait-orientated)
    int srcW = gSrcWidth;
    int srcH = gSrcHeight;
    if (srcW <= 0 || srcH <= 0)
        return;

    // Rotate at source dimension stage
    int rotW = (rotQ % 2 == 0) ? srcW : srcH;
    int rotH = (rotQ % 2 == 0) ? srcH : srcW;

    // Apply output scaling then align width to multiple of 4 (adjust height to preserve aspect)
    int outWraw = (gScale > 0.0 && gScale < 1.0) ? MAX(1, (int)floor((double)rotW * gScale)) : rotW;
    int outHraw = (gScale > 0.0 && gScale < 1.0) ? MAX(1, (int)floor((double)rotH * gScale)) : rotH;
    int outW = 0, outH = 0;
    alignDimensions(outWraw, outHraw, &outW, &outH);

    if (outW == gWidth && outH == gHeight)
        return; // no change

    // Allocate new double buffers
    size_t newFBSize = (size_t)outW * (size_t)outH * (size_t)gBytesPerPixel;
    void *newFront = calloc(1, newFBSize);
    void *newBack = calloc(1, newFBSize);
    if (!newFront || !newBack) {
        if (newFront)
            free(newFront);
        if (newBack)
            free(newBack);
        fprintf(stderr, "Failed to allocate required frame buffers\n");
        exit(EXIT_FAILURE);
    }

    // Swap buffers into screen & notify clients
    gWidth = outW;
    gHeight = outH;
    gFBSize = newFBSize;

    if (gScreen) {
        // Update server with new framebuffer
        rfbNewFramebuffer(gScreen, (char *)newFront, gWidth, gHeight, 8, 3, gBytesPerPixel);
        // Restore BGRA little-endian channel layout (R shift=16, G=8, B=0)
        int bps = 8;
        gScreen->serverFormat.redShift = bps * 2;   // 16
        gScreen->serverFormat.greenShift = bps * 1; // 8
        gScreen->serverFormat.blueShift = 0;        // 0
        gScreen->paddedWidthInBytes = gWidth * gBytesPerPixel;
    }

    // Free old buffers and store new pointers
    if (gFrontBuffer)
        free(gFrontBuffer);
    if (gBackBuffer)
        free(gBackBuffer);
    gFrontBuffer = newFront;
    gBackBuffer = newBack;

    // Keep gScreen->frameBuffer in sync (rfbNewFramebuffer already did, but ensure local)
    if (gScreen)
        gScreen->frameBuffer = (char *)gFrontBuffer;

    // Re-init tiling/hash state for new geometry
    initializeTilingOrReset();
    // Clear pending dirty flags to avoid carrying over old-geometry state into the new geometry
    if (gPendingDirty)
        memset(gPendingDirty, 0, gTileCount);

    gHasPending = NO;
    TVLog(@"Resize: framebuffer changed to %dx%d (rotQ=%d, scale=%.3f)", gWidth, gHeight, rotQ, gScale);
}

// Ensure scratch buffer for rotation is available and large enough
NS_INLINE int ensureRotateScratch(size_t w, size_t h) {
    size_t need = w * h * (size_t)gBytesPerPixel;
    if (need == 0)
        return -1;
    if (gRotateScratchSize >= need && gRotateScratch)
        return 0;
    void *nbuf = realloc(gRotateScratch, need);
    memset(nbuf, 0, need);
    if (!nbuf)
        return -1;
    gRotateScratch = nbuf;
    gRotateScratchSize = need;
    return 0;
}

NS_INLINE int ensureScaleTemp(size_t srcW, size_t srcH, size_t dstW, size_t dstH, vImage_Flags flags) {
    vImage_Buffer s = {.data = NULL,
                       .width = (vImagePixelCount)srcW,
                       .height = (vImagePixelCount)srcH,
                       .rowBytes = srcW * (size_t)gBytesPerPixel};
    vImage_Buffer d = {.data = NULL,
                       .width = (vImagePixelCount)dstW,
                       .height = (vImagePixelCount)dstH,
                       .rowBytes = dstW * (size_t)gBytesPerPixel};
    vImage_Error need = vImageScale_ARGB8888(&s, &d, NULL, flags | kvImageGetTempBufferSize);
    if (need < 0)
        return -1;
    size_t nbytes = (size_t)need;
    if (nbytes == 0)
        return 0;
    if (gScaleTempSize >= nbytes && gScaleTemp)
        return 0;
    void *nbuf = realloc(gScaleTemp, nbytes);
    memset(nbuf, 0, nbytes);
    if (!nbuf)
        return -1;
    gScaleTemp = nbuf;
    gScaleTempSize = nbytes;
    return 0;
}

// Row-by-row copy to convert a possibly-strided captured buffer into a tightly packed VNC buffer.
NS_INLINE void copyWithStrideTight(uint8_t *dstTight, const uint8_t *src, int width, int height,
                                   size_t srcBytesPerRow) {
    size_t dstBPR = (size_t)width * gBytesPerPixel;
    for (int y = 0; y < height; ++y) {
        memcpy(dstTight + (size_t)y * dstBPR, src + (size_t)y * srcBytesPerRow, dstBPR);
    }
}

// Copy with small pad/crop to avoid expensive scaling when sizes are close.
// Strategy:
// - Copy overlap region at (0,0) with width=min(srcW,dstW), height=min(srcH,dstH)
// - If dst wider, horizontally replicate the last pixel in each row to fill the right pad.
// - If dst taller, vertically replicate the last valid row to fill the bottom pad.
NS_INLINE void copyPadOrCropToTight(uint8_t *dstTight, int dstW, int dstH, const uint8_t *src, int srcW, int srcH,
                                    size_t srcBytesPerRow) {
    const int bpp = gBytesPerPixel;
    const size_t dstBPR = (size_t)dstW * (size_t)bpp;
    const int overlapW = srcW < dstW ? srcW : dstW;
    const int overlapH = srcH < dstH ? srcH : dstH;

    // 1) Copy overlap region row-by-row
    if (overlapW > 0 && overlapH > 0) {
        const size_t copyBytes = (size_t)overlapW * (size_t)bpp;
        for (int y = 0; y < overlapH; ++y) {
            uint8_t *drow = dstTight + (size_t)y * dstBPR;
            const uint8_t *srow = src + (size_t)y * srcBytesPerRow;
            memcpy(drow, srow, copyBytes);
            // 2) Right pad by replicating last pixel if needed
            if (dstW > overlapW) {
                const uint8_t *lastPx = (overlapW > 0) ? (drow + ((size_t)overlapW - 1) * (size_t)bpp) : drow;
                for (int x = overlapW; x < dstW; ++x) {
                    memcpy(drow + (size_t)x * (size_t)bpp, lastPx, (size_t)bpp);
                }
            }
        }
    }

    // 3) Bottom pad by replicating last valid row if needed
    if (dstH > overlapH) {
        uint8_t *lastRow = (overlapH > 0) ? (dstTight + (size_t)(overlapH - 1) * dstBPR) : dstTight;
        for (int y = overlapH; y < dstH; ++y) {
            uint8_t *drow = dstTight + (size_t)y * dstBPR;
            memcpy(drow, lastRow, dstBPR);
        }
    }
}

NS_INLINE void swapBuffers(void) {
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
NS_INLINE void lockAllClientsBlocking(void) {
    rfbClientIteratorPtr it = rfbGetClientIterator(gScreen);
    rfbClientPtr cl;
    while ((cl = rfbClientIteratorNext(it))) {
        pthread_mutex_lock(&cl->sendMutex);
    }
    rfbReleaseClientIterator(it);
}

NS_INLINE void unlockAllClientsBlocking(void) {
    rfbClientIteratorPtr it = rfbGetClientIterator(gScreen);
    rfbClientPtr cl;
    while ((cl = rfbClientIteratorNext(it))) {
        pthread_mutex_unlock(&cl->sendMutex);
    }
    rfbReleaseClientIterator(it);
}

static void handleFramebuffer(CMSampleBufferRef sampleBuffer) {

#if FB_LOG
    // Perf: overall start timestamp
    CFAbsoluteTime __tv_tStart = CFAbsoluteTimeGetCurrent();
#endif

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) {
        FBLog(@"sampleBuffer has no image buffer (skip)");
        return;
    }

    // Busy-drop: if encoders are busy and limit reached, skip this frame (disabled when -Q 0)
    if (gMaxInflightUpdates > 0 && gInflight.load(std::memory_order_relaxed) >= gMaxInflightUpdates) {
        // When busy dropping, skip all hashing/dirty work.
        FBLog(@"drop frame due to inflight=%d >= limit=%d", gInflight.load(std::memory_order_relaxed),
              gMaxInflightUpdates);
        return;
    }

#if FB_LOG
    CFAbsoluteTime __tv_tLock0 = CFAbsoluteTimeGetCurrent();
#endif

    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

#if FB_LOG
    CFAbsoluteTime __tv_tLock1 = CFAbsoluteTimeGetCurrent();
    CFTimeInterval __tv_msLock = (__tv_tLock1 - __tv_tLock0) * 1000.0;
    FBLog(@"lock pixel buffer took %.3f ms", __tv_msLock);
#endif

    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    const size_t srcBPR = (size_t)CVPixelBufferGetBytesPerRow(pb);
    const size_t width = (size_t)CVPixelBufferGetWidth(pb);
    const size_t height = (size_t)CVPixelBufferGetHeight(pb);

    // Determine rotation and resize framebuffer if orientation implies new dimensions.
    int rotQ = (gOrientationSyncEnabled ? gRotationQuad.load(std::memory_order_relaxed) : 0) & 3;

#if FB_LOG
    CFAbsoluteTime __tv_tResize0 = CFAbsoluteTimeGetCurrent();
#endif

    maybeResizeFramebufferForRotation(rotQ);

#if FB_LOG
    CFAbsoluteTime __tv_tResize1 = CFAbsoluteTimeGetCurrent();
    CFTimeInterval __tv_msResize = (__tv_tResize1 - __tv_tResize0) * 1000.0;
    FBLog(@"maybeResize(rotQ=%d) took %.3f ms (server=%dx%d, src=%zux%zu)", rotQ, __tv_msResize, gWidth, gHeight, width,
          height);
#endif

    if ((int)width != gWidth || (int)height != gHeight) {
        // With scaling enabled, this is expected; log once for info. Without scaling, warn once.
        static BOOL sLoggedSizeInfoOnce = NO;
        if (!sLoggedSizeInfoOnce) {
            sLoggedSizeInfoOnce = YES;
            if (gScale != 1.0) {
                TVLog(@"Scaling source %zux%zu -> output %dx%d (scale=%.3f)", width, height, gWidth, gHeight, gScale);
            } else {
                TVLog(@"Captured frame size %zux%zu differs from server %dx%d; cropping/copying minimum region.", width,
                      height, gWidth, gHeight);
            }
        }
    }

    // Copy/Rotate/Scale into back buffer. ScreenCapturer is always portrait-oriented.
    // We rotate by UI orientation then scale to server size.
    BOOL dirtyDisabled = (gFullscreenThresholdPercent == 0);

    static int sLastRotQ = -1;
    bool rotationChanged = (sLastRotQ == -1) ? false : ((rotQ & 3) != (sLastRotQ & 3));
    bool needsRotate = (rotQ != 0);

    vImage_Buffer srcBuf = {
        .data = base, .height = (vImagePixelCount)height, .width = (vImagePixelCount)width, .rowBytes = srcBPR};

    vImage_Buffer stage = srcBuf; // after rotation
    vImage_Buffer rotBuf = {0};

#if FB_LOG
    CFTimeInterval __tv_msRotate = 0.0;
    CFTimeInterval __tv_msScaleOrCopy = 0.0;
#endif

    if (needsRotate) {

#if FB_LOG
        CFAbsoluteTime __tv_tRot0 = CFAbsoluteTimeGetCurrent();
#endif

        size_t rotW = (rotQ % 2 == 0) ? (size_t)width : (size_t)height;
        size_t rotH = (rotQ % 2 == 0) ? (size_t)height : (size_t)width;
        if (ensureRotateScratch(rotW, rotH) != 0) {
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            return;
        }

        rotBuf.data = gRotateScratch;
        rotBuf.width = (vImagePixelCount)rotW;
        rotBuf.height = (vImagePixelCount)rotH;
        rotBuf.rowBytes = rotW * (size_t)gBytesPerPixel;

        uint8_t rotConst = kRotate0DegreesClockwise;
        switch (rotQ) {
        case 1:
            rotConst = kRotate90DegreesClockwise;
            break;
        case 2:
            rotConst = kRotate180DegreesClockwise;
            break;
        case 3:
            rotConst = kRotate270DegreesClockwise;
            break;
        default:
            rotConst = kRotate0DegreesClockwise;
            break;
        }

        uint8_t bg[4] = {0, 0, 0, 0};
        vImage_Error rerr = vImageRotate90_ARGB8888(&srcBuf, &rotBuf, rotConst, bg, kvImageNoFlags);
        if (rerr != kvImageNoError) {
            static BOOL sLoggedRotErrOnce = NO;
            if (!sLoggedRotErrOnce) {
                sLoggedRotErrOnce = YES;
                TVLog(@"vImageRotate90_ARGB8888 failed: %ld", (long)rerr);
            }

            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            return;
        }

        stage = rotBuf;

#if FB_LOG
        CFAbsoluteTime __tv_tRot1 = CFAbsoluteTimeGetCurrent();
        __tv_msRotate = (__tv_tRot1 - __tv_tRot0) * 1000.0;
        FBLog(@"rotate %d*90 took %.3f ms (rotW=%zu, rotH=%zu)", rotQ, __tv_msRotate, (size_t)rotBuf.width,
              (size_t)rotBuf.height);
#endif
    }

    // Scale stage to back buffer (tightly packed)
    vImage_Buffer dstBuf = {.data = gBackBuffer,
                            .height = (vImagePixelCount)gHeight,
                            .width = (vImagePixelCount)gWidth,
                            .rowBytes = (size_t)gWidth * (size_t)gBytesPerPixel};
    if (stage.width == dstBuf.width && stage.height == dstBuf.height && gScale == 1.0) {

#if FB_LOG
        CFAbsoluteTime __tv_tCopy0 = CFAbsoluteTimeGetCurrent();
#endif

        copyWithStrideTight((uint8_t *)dstBuf.data, (const uint8_t *)stage.data, gWidth, gHeight, stage.rowBytes);

#if FB_LOG
        CFAbsoluteTime __tv_tCopy1 = CFAbsoluteTimeGetCurrent();
        __tv_msScaleOrCopy = (__tv_tCopy1 - __tv_tCopy0) * 1000.0;
        FBLog(@"copy stage->back (tight) took %.3f ms", __tv_msScaleOrCopy);
#endif

    } else {

        // Small-diff pad/crop fast path to avoid vImageScale when sizes are close
        int dW = (int)dstBuf.width - (int)stage.width;
        int dH = (int)dstBuf.height - (int)stage.height;
        if (gNoScalePadThresholdPx > 0 && dW <= gNoScalePadThresholdPx && dW >= -gNoScalePadThresholdPx &&
            dH <= gNoScalePadThresholdPx && dH >= -gNoScalePadThresholdPx) {

#if FB_LOG
            CFAbsoluteTime __tv_tPad0 = CFAbsoluteTimeGetCurrent();
#endif

            copyPadOrCropToTight((uint8_t *)dstBuf.data, (int)dstBuf.width, (int)dstBuf.height,
                                 (const uint8_t *)stage.data, (int)stage.width, (int)stage.height, stage.rowBytes);

#if FB_LOG
            CFAbsoluteTime __tv_tPad1 = CFAbsoluteTimeGetCurrent();
            __tv_msScaleOrCopy = (__tv_tPad1 - __tv_tPad0) * 1000.0;
            FBLog(@"pad/crop copy stage->back took %.3f ms (stage=%zux%zu -> dst=%dx%d, thr=%d)", __tv_msScaleOrCopy,
                  (size_t)stage.width, (size_t)stage.height, gWidth, gHeight, gNoScalePadThresholdPx);
#endif

        } else {

#if FB_LOG
            CFAbsoluteTime __tv_tScale0 = CFAbsoluteTimeGetCurrent();
#endif

            if (ensureScaleTemp(stage.width, stage.height, dstBuf.width, dstBuf.height, kvImageHighQualityResampling) !=
                0) {
                CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                return;
            }

            vImage_Error err = vImageScale_ARGB8888(&stage, &dstBuf, gScaleTemp, kvImageHighQualityResampling);
            if (err != kvImageNoError) {
                static BOOL sLoggedVImageErrOnce = NO;
                if (!sLoggedVImageErrOnce) {
                    sLoggedVImageErrOnce = YES;
                    TVLog(@"vImageScale_ARGB8888 failed: %ld", (long)err);
                }
                CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                return;
            }

#if FB_LOG
            CFAbsoluteTime __tv_tScale1 = CFAbsoluteTimeGetCurrent();
            __tv_msScaleOrCopy = (__tv_tScale1 - __tv_tScale0) * 1000.0;
            FBLog(@"scale stage->back took %.3f ms (stage=%zux%zu -> dst=%dx%d)", __tv_msScaleOrCopy,
                  (size_t)stage.width, (size_t)stage.height, gWidth, gHeight);
#endif
        }
    }

#if FB_LOG
    CFAbsoluteTime __tv_tUnlock0 = CFAbsoluteTimeGetCurrent();
#endif

    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

#if FB_LOG
    CFAbsoluteTime __tv_tUnlock1 = CFAbsoluteTimeGetCurrent();
    CFTimeInterval __tv_msUnlock = (__tv_tUnlock1 - __tv_tUnlock0) * 1000.0;
    FBLog(@"unlock pixel buffer took %.3f ms", __tv_msUnlock);
#endif

    // If rotation just changed, force a full-screen update and reset dirty state
    // to avoid mixing hashes/pending dirties from the previous orientation.
    if (rotationChanged) {
        // Clear pending mask/state
        if (gPendingDirty)
            memset(gPendingDirty, 0, gTileCount);
        gHasPending = NO;

#if FB_LOG
        CFAbsoluteTime __tv_tSwap0 = CFAbsoluteTimeGetCurrent();
#endif

        if (gAsyncSwapEnabled) {
            pthread_mutex_t *locked[64];
            size_t lockedCount = 0;
            if (tryLockAllClients(locked, &lockedCount, sizeof(locked) / sizeof(locked[0]))) {
                swapBuffers();
                for (size_t i = 0; i < lockedCount; ++i)
                    pthread_mutex_unlock(locked[i]);
                rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);

#if FB_LOG
                CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
                FBLog(@"rotationChanged async-swap+mark fullscreen took %.3f ms", (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif

            } else {
                copyWithStrideTight((uint8_t *)gFrontBuffer, (uint8_t *)gBackBuffer, gWidth, gHeight,
                                    (size_t)gWidth * (size_t)gBytesPerPixel);
                rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);

#if FB_LOG
                CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
                FBLog(@"rotationChanged copy(fullscreen)+mark took %.3f ms", (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif
            }
        } else {
            lockAllClientsBlocking();
            swapBuffers();
            rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);
            unlockAllClientsBlocking();

#if FB_LOG
            CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
            FBLog(@"rotationChanged blocking-swap+mark fullscreen took %.3f ms", (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif
        }

        // Skip dirty detection for this frame after rotation; return early
        sLastRotQ = rotQ;

        // Rotation may not change geometry (0<->180). Maintain hashes here so
        // the next frame recomputes curr and swaps to form a clean baseline.
        resetCurrTileHashes();
        swapTileHashes();

#if FB_LOG
        CFAbsoluteTime __tv_tEnd = CFAbsoluteTimeGetCurrent();
        FBLog(@"rotationChanged summary rotQ=%d lock=%.3fms resize=%.3fms rotate=%.3fms scale/copy=%.3fms "
              @"total=%.3fms",
              rotQ, __tv_msLock, __tv_msResize, __tv_msRotate, __tv_msScaleOrCopy, (__tv_tEnd - __tv_tStart) * 1000.0);
#endif

        return;
    }

    // If dirty detection is disabled, perform a full-screen update
    if (dirtyDisabled) {

#if FB_LOG
        CFAbsoluteTime __tv_tSwap0 = CFAbsoluteTimeGetCurrent();
#endif

        if (gAsyncSwapEnabled) {
            pthread_mutex_t *locked[64];
            size_t lockedCount = 0;
            if (tryLockAllClients(locked, &lockedCount, sizeof(locked) / sizeof(locked[0]))) {
                swapBuffers();
                for (size_t i = 0; i < lockedCount; ++i)
                    pthread_mutex_unlock(locked[i]);
                rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);

#if FB_LOG
                CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
                FBLog(@"dirtyDisabled async-swap+mark fullscreen took %.3f ms", (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif

            } else {
                // Whole screen copy fallback (tight -> tight)
                copyWithStrideTight((uint8_t *)gFrontBuffer, (uint8_t *)gBackBuffer, gWidth, gHeight,
                                    (size_t)gWidth * (size_t)gBytesPerPixel);
                rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);

#if FB_LOG
                CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
                FBLog(@"dirtyDisabled copy(fullscreen)+mark took %.3f ms", (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif
            }
        } else {
            // Blocking swap to avoid tearing
            lockAllClientsBlocking();
            swapBuffers();
            rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);
            unlockAllClientsBlocking();

#if FB_LOG
            CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
            FBLog(@"dirtyDisabled blocking-swap+mark fullscreen took %.3f ms", (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif
        }

#if FB_LOG
        CFAbsoluteTime __tv_tEnd = CFAbsoluteTimeGetCurrent();
        FBLog(@"dirtyDisabled summary rotQ=%d lock=%.3fms resize=%.3fms rotate=%.3fms scale/copy=%.3fms total=%.3fms",
              rotQ, __tv_msLock, __tv_msResize, __tv_msRotate, __tv_msScaleOrCopy, (__tv_tEnd - __tv_tStart) * 1000.0);
#endif

        return;
    }

    // Build dirty rectangles with deferred coalescing window (enabled)
    // Lightweight hashing to update pending and decide whether to flush.

#if FB_LOG
    CFAbsoluteTime __tv_tHash0 = CFAbsoluteTimeGetCurrent();
#endif

    if (gSparseHashDuringDefer && gDeferWindowSec > 0) {
        hashTiledFromBufferSparse((const uint8_t *)gBackBuffer, gWidth, gHeight,
                                  (size_t)gWidth * (size_t)gBytesPerPixel, gHashStrideX, gHashStrideY);
    } else {
        resetCurrTileHashes();
        hashTiledFromBuffer((const uint8_t *)gBackBuffer, gWidth, gHeight, (size_t)gWidth * (size_t)gBytesPerPixel);
    }

#if FB_LOG
    CFAbsoluteTime __tv_tHash1 = CFAbsoluteTimeGetCurrent();
    CFTimeInterval __tv_msHash = (__tv_tHash1 - __tv_tHash0) * 1000.0;
    FBLog(@"tile hashing took %.3f ms (tiles=%zu, tileSize=%d)%@%@", __tv_msHash, gTileCount, gTileSize,
          (gSparseHashDuringDefer && gDeferWindowSec > 0) ? @" [sparse]" : @"",
          gUseCRC32Hash ? @" [crc32]" : @" [fnv]");
#endif

    enum { kRectBuf = 1024 };
    DirtyRect rects[kRectBuf];
    int changedTiles = 0;

    // Accumulate pending dirty tiles

#if FB_LOG
    CFAbsoluteTime __tv_tPend0 = CFAbsoluteTimeGetCurrent();
#endif

    accumulatePendingDirty();

#if FB_LOG
    CFAbsoluteTime __tv_tPend1 = CFAbsoluteTimeGetCurrent();
    CFTimeInterval __tv_msPend = (__tv_tPend1 - __tv_tPend0) * 1000.0;
    FBLog(@"accumulate pending took %.3f ms (hasPending=%@)", __tv_msPend, gHasPending ? @"YES" : @"NO");
#endif

    // Decide whether to flush now
    BOOL shouldFlush = YES;
    static CFAbsoluteTime sDeferStartTime = 0;
    if (gDeferWindowSec > 0) {
        if (!gHasPending) {
            gHasPending = YES;
            sDeferStartTime = CFAbsoluteTimeGetCurrent();
            shouldFlush = NO; // start window, wait for more
        } else {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            shouldFlush = ((now - sDeferStartTime) >= gDeferWindowSec);
            FBLog(@"defer window elapsed=%.3f ms (threshold=%.3f ms) -> %@", (now - sDeferStartTime) * 1000.0,
                  gDeferWindowSec * 1000.0, shouldFlush ? @"FLUSH" : @"WAIT");
        }
    }

    int rectCount = 0;
    int changedPct = 0;
    BOOL fullScreen = NO;

    if (!shouldFlush) {
        // Still deferring: do not notify clients yet; keep previous full-hash baseline.

#if FB_LOG
        CFAbsoluteTime __tv_tEnd = CFAbsoluteTimeGetCurrent();
        FBLog(@"deferred (no flush) summary rotQ=%d lock=%.3fms resize=%.3fms rotate=%.3fms scale/copy=%.3fms "
              @"hash=%.3fms total=%.3fms",
              rotQ, __tv_msLock, __tv_msResize, __tv_msRotate, __tv_msScaleOrCopy, __tv_msHash,
              (__tv_tEnd - __tv_tStart) * 1000.0);
#endif

        return;
    }

    // At flush: recompute full hashes for precise rects
    {

#if FB_LOG
        CFAbsoluteTime __tv_tHashFull0 = CFAbsoluteTimeGetCurrent();
#endif

        if (gParallelHashOnFlush) {
            // Use number of logical CPUs as thread hint (capped)
            int threads = (int)[[NSProcessInfo processInfo] processorCount];
            if (threads < 2)
                threads = 2;
            if (threads > 8)
                threads = 8;
            hashTiledFromBufferParallel((const uint8_t *)gBackBuffer, gWidth, gHeight,
                                        (size_t)gWidth * (size_t)gBytesPerPixel, threads);
        } else {
            resetCurrTileHashes();
            hashTiledFromBuffer((const uint8_t *)gBackBuffer, gWidth, gHeight, (size_t)gWidth * (size_t)gBytesPerPixel);
        }

#if FB_LOG
        CFAbsoluteTime __tv_tHashFull1 = CFAbsoluteTimeGetCurrent();
        __tv_msHash = (__tv_tHashFull1 - __tv_tHashFull0) * 1000.0;
        FBLog(@"tile hashing (flush full)%@ took %.3f ms (tiles=%zu, tileSize=%d)%@",
              gParallelHashOnFlush ? @" [parallel]" : @"", __tv_msHash, gTileCount, gTileSize,
              gUseCRC32Hash ? @" [crc32]" : @" [fnv]");
#endif
    }

// Promote pending tiles into rects
#if FB_LOG
    CFAbsoluteTime __tv_tRects0 = CFAbsoluteTimeGetCurrent();
#endif

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

        FBLog(@"rects exceeded limit -> collapse to bbox");
    }

    fullScreen = (changedPct >= gFullscreenThresholdPercent) || rectCount == 0;

#if FB_LOG
    CFAbsoluteTime __tv_tRects1 = CFAbsoluteTimeGetCurrent();
    CFTimeInterval __tv_msRects = (__tv_tRects1 - __tv_tRects0) * 1000.0;
    FBLog(@"build rects took %.3f ms (rects=%d, changedTiles=%d, extraTiles=%d, changedPct=%d%%, fsThresh=%d%%, "
          @"fullscreen=%@)",
          __tv_msRects, rectCount, changedTiles, extraTiles, changedPct, gFullscreenThresholdPercent,
          fullScreen ? @"YES" : @"NO");
#endif

    // Clear pending
    if (gPendingDirty)
        memset(gPendingDirty, 0, gTileCount);

    gHasPending = NO;

#if FB_LOG
    CFAbsoluteTime __tv_tSwap0 = CFAbsoluteTimeGetCurrent();
#endif

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

#if FB_LOG
            CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
            FBLog(@"async-swap+mark took %.3f ms (%@)", (__tv_tSwap1 - __tv_tSwap0) * 1000.0,
                  fullScreen ? @"fullscreen" : @"partial");
#endif

        } else {
            if (fullScreen) {
                // Whole screen copy fallback (tight -> tight)
                copyWithStrideTight((uint8_t *)gFrontBuffer, (uint8_t *)gBackBuffer, gWidth, gHeight,
                                    (size_t)gWidth * (size_t)gBytesPerPixel);
                rfbMarkRectAsModified(gScreen, 0, 0, gWidth, gHeight);

#if FB_LOG
                CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
                FBLog(@"async path copy(fullscreen)+mark took %.3f ms", (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif

            } else {
                // Only copy dirty regions from back to front to reduce tearing and bandwidth
                copyRectsFromBackToFront(rects, rectCount);
                markRectsModified(rects, rectCount);

#if FB_LOG
                CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
                FBLog(@"async path copy(dirty %d rects)+mark took %.3f ms", rectCount,
                      (__tv_tSwap1 - __tv_tSwap0) * 1000.0);
#endif
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

#if FB_LOG
        CFAbsoluteTime __tv_tSwap1 = CFAbsoluteTimeGetCurrent();
        FBLog(@"blocking-swap+mark took %.3f ms (%@)", (__tv_tSwap1 - __tv_tSwap0) * 1000.0,
              fullScreen ? @"fullscreen" : @"partial");
#endif
    }

    // Prepare for next frame: current hashes become previous
    swapTileHashes();
    sLastRotQ = rotQ;

#if FB_LOG
    CFAbsoluteTime __tv_tEnd = CFAbsoluteTimeGetCurrent();
    FBLog(@"frame summary rotQ=%d lock=%.3fms resize=%.3fms rotate=%.3fms scale/copy=%.3fms hash=%.3fms "
          @"rects=%.3fms total=%.3fms (rectCount=%d, changedPct=%d%%, fullscreen=%@, inflight=%d/%d)",
          rotQ, __tv_msLock, __tv_msResize, __tv_msRotate, __tv_msScaleOrCopy, __tv_msHash, __tv_msRects,
          (__tv_tEnd - __tv_tStart) * 1000.0, rectCount, changedPct, fullScreen ? @"YES" : @"NO",
          gInflight.load(std::memory_order_relaxed), gMaxInflightUpdates);
#endif
}

#pragma mark - Event Handlers

NS_INLINE NSString *keysymToString(rfbKeySym ks) {
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

static void kbdAddEvent(rfbBool down, rfbKeySym keySym, rfbClientPtr cl) {
    (void)cl;
    if (gViewOnly)
        return;

    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];

    // Map common XF86 multimedia/brightness keysyms to iOS HID events
    switch ((unsigned long)keySym) {
    // Brightness Up/Down
    case 0x1008ff02UL: // XF86MonBrightnessUp
        if (down)
            [gen displayBrightnessIncrementDown];
        else
            [gen displayBrightnessIncrementUp];
        return;
    case 0x1008ff03UL: // XF86MonBrightnessDown
        if (down)
            [gen displayBrightnessDecrementDown];
        else
            [gen displayBrightnessDecrementUp];
        return;
    // Volume/Mute
    case 0x1008ff13UL: // XF86AudioRaiseVolume
        if (down)
            [gen volumeIncrementDown];
        else
            [gen volumeIncrementUp];
        return;
    case 0x1008ff11UL: // XF86AudioLowerVolume
        if (down)
            [gen volumeDecrementDown];
        else
            [gen volumeDecrementUp];
        return;
    case 0x1008ff12UL: // XF86AudioMute
        if (down)
            [gen muteDown];
        else
            [gen muteUp];
        return;
    // Media keys: Previous / Play-Pause / Next (use Consumer usages)
    case 0x1008ff3eUL: // Map as Previous Track (per user observation)
        if (down)
            [gen otherConsumerUsageDown:kHIDUsage_Csmr_ScanPreviousTrack];
        else
            [gen otherConsumerUsageUp:kHIDUsage_Csmr_ScanPreviousTrack];
        return;
    case 0x1008ff14UL: // XF86AudioPlay (toggle Play/Pause)
        if (down)
            [gen otherConsumerUsageDown:kHIDUsage_Csmr_PlayOrPause];
        else
            [gen otherConsumerUsageUp:kHIDUsage_Csmr_PlayOrPause];
        return;
    case 0x1008ff97UL: // Map as Next Track (per user observation)
        if (down)
            [gen otherConsumerUsageDown:kHIDUsage_Csmr_ScanNextTrack];
        else
            [gen otherConsumerUsageUp:kHIDUsage_Csmr_ScanNextTrack];
        return;
    default:
        break;
    }

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

NS_INLINE CGPoint vncPointToDevicePoint(int vx, int vy) {
    // Map from VNC framebuffer space (gWidth x gHeight, post-rotation & scaling)
    // back to device capture space (portrait, gSrcWidth x gSrcHeight), inverting rotation.
    int rotQ = (gOrientationSyncEnabled ? gRotationQuad.load(std::memory_order_relaxed) : 0) & 3;

    // Dimensions of the rotated (pre-scale) stage
    int rotW = (rotQ % 2 == 0) ? gSrcWidth : gSrcHeight;
    int rotH = (rotQ % 2 == 0) ? gSrcHeight : gSrcWidth;

    // Undo scaling from stage(rotW x rotH) -> VNC(gWidth x gHeight)
    double sx = (gWidth > 0) ? ((double)rotW / (double)gWidth) : 1.0;
    double sy = (gHeight > 0) ? ((double)rotH / (double)gHeight) : 1.0;
    double stX = sx * (double)vx;
    double stY = sy * (double)vy;

    // Clamp to stage bounds
    if (stX < 0)
        stX = 0;
    if (stY < 0)
        stY = 0;
    if (stX > (double)(rotW - 1))
        stX = (double)(rotW - 1);
    if (stY > (double)(rotH - 1))
        stY = (double)(rotH - 1);

    // Invert rotation: stage -> source portrait space
    double dx = 0.0, dy = 0.0;
    switch (rotQ) {
    case 0: // identity
        dx = stX;
        dy = stY;
        break;
    case 1: // 90 CW: inverse of stageX=srcH-1-srcY, stageY=srcX -> srcX=stageY; srcY=srcH-1-stageX
        dx = stY;
        dy = (double)(gSrcHeight - 1) - stX;
        break;
    case 2: // 180: srcX = srcW-1 - stageX; srcY = srcH-1 - stageY
        dx = (double)(gSrcWidth - 1) - stX;
        dy = (double)(gSrcHeight - 1) - stY;
        break;
    case 3: // 270 CW (90 CCW): inverse of stageX=srcY, stageY=srcW-1-srcX -> srcX=srcW-1-stageY; srcY=stageX
        dx = (double)(gSrcWidth - 1) - stY;
        dy = stX;
        break;
    }

    // Final clamp to device bounds
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

@interface STHIDEventGenerator (Private)
- (void)touchDownAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
- (void)liftUpAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
- (void)_updateTouchPoints:(CGPoint *)points count:(NSUInteger)count;
@end

// Track last button state to detect edges; per-process (typical single client).
static int gLastButtonMask = 0;
static dispatch_queue_t gWheelQueue = nil; // serial queue for wheel gestures
static double gWheelAccumPx = 0.0;         // accumulated scroll in pixels (+down, -up)
static BOOL gWheelFlushScheduled = NO;     // whether a flush is pending

static void wheelScheduleFlush(CGPoint anchorPoint, double delaySec, int rotQ) {
    if (gWheelStepPx <= 0) { // disabled
        gWheelAccumPx = 0.0;
        gWheelFlushScheduled = NO;
        return;
    }

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

        // Map VNC-vertical delta into device axis based on rotation
        CGFloat dx = 0, dy = 0;
        switch (rotQ & 3) {
        case 0: // portrait
            dx = 0;
            dy = (CGFloat)take;
            break;
        case 2: // upside-down
            dx = 0;
            dy = (CGFloat)(-take);
            break;
        case 1: // landscape left (90 CW)
            dx = (CGFloat)(+take);
            dy = 0;
            break;
        case 3: // landscape right (270 CW)
            dx = (CGFloat)(-take);
            dy = 0;
            break;
        }

        CGFloat endX = anchorPoint.x + dx;
        CGFloat endY = anchorPoint.y + dy;
        if (endX < 0)
            endX = 0;
        CGFloat maxX = (CGFloat)gSrcWidth - 1;
        if (endX > maxX)
            endX = maxX;
        if (endY < 0)
            endY = 0;
        CGFloat maxY = (CGFloat)gSrcHeight - 1;
        if (endY > maxY)
            endY = maxY;
        CGPoint endPt = CGPointMake(endX, endY);

        // Duration scales sub-linearly with distance; parameters configurable
        double dur = gWheelDurBase + gWheelDurK * sqrt(fabs(take));
        if (dur > gWheelDurMax)
            dur = gWheelDurMax;
        if (dur < gWheelDurMin)
            dur = gWheelDurMin;

        [[STHIDEventGenerator sharedGenerator] dragLinearWithStartPoint:anchorPoint endPoint:endPt duration:dur];
    });
}

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
        gWheelQueue = dispatch_queue_create("com.82flex.trollvnc.wheel", DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);
    }
    if (gWheelStepPx > 0 && ((wheelUpNow && !wheelUpPrev) || (wheelDnNow && !wheelDnPrev))) {
        double delta = (wheelDnNow && !wheelDnPrev) ? +gWheelStepPx : -gWheelStepPx;
        if (gWheelNaturalDir)
            delta = -delta;
        int rotQ = (gOrientationSyncEnabled ? gRotationQuad.load(std::memory_order_relaxed) : 0) & 3;
        dispatch_async(gWheelQueue, ^{
            gWheelAccumPx += delta;
            if (!gWheelFlushScheduled) {
                gWheelFlushScheduled = YES;
                wheelScheduleFlush(pt, gWheelCoalesceSec, rotQ);
            }
        });
    }

    gLastButtonMask = buttonMask;
}

#pragma mark - Client Handlers

static int gClientCount = 0; // Number of connected clients
static BOOL gIsCaptureStarted = NO;
static BOOL gIsClipboardStarted = NO;

static void clientGone(rfbClientPtr cl) {
    // Decrement client count and stop capture if this was the last client.
    if (gClientCount > 0)
        gClientCount--;

    TVLog(@"Client disconnected, active clients=%d", gClientCount);

    if (gIsCaptureStarted && gClientCount == 0) {
        [[ScreenCapturer sharedCapturer] endCapture];
        gIsCaptureStarted = NO;
        TVLog(@"No clients remaining; screen capture stopped.");
    }

    if (gIsClipboardStarted && gClientCount == 0) {
        [[ClipboardManager sharedManager] stop];
        gIsClipboardStarted = NO;
        TVLog(@"No clients remaining; clipboard listening stopped.");
    }

    // KeepAlive: disable when no clients remain
    if (gClientCount == 0) {
        [[STHIDEventGenerator sharedGenerator] setKeepAliveInterval:0];
        TVLog(@"No clients remaining; KeepAlive stopped.");
    }
}

static enum rfbNewClientAction newClientHook(rfbClientPtr cl) {
    cl->clientGoneHook = clientGone;
    cl->viewOnly = gViewOnly ? TRUE : FALSE;

    gClientCount++;
    TVLog(@"Client connected, active clients=%d", gClientCount);

    if (!gIsCaptureStarted && gClientCount > 0 && gFrameHandler) {
        // Start capture when entering non-zero client population.
        gIsCaptureStarted = YES;
        [[ScreenCapturer sharedCapturer] startCaptureWithFrameHandler:gFrameHandler];
        TVLog(@"Screen capture started (clients=%d).", gClientCount);
    }

    if (gClipboardEnabled && !gIsClipboardStarted && gClientCount > 0) {
        gIsClipboardStarted = YES;
        [[ClipboardManager sharedManager] start];
        TVLog(@"Clipboard listening started (clients=%d).", gClientCount);
    }

    // KeepAlive: enable when at least one client is connected and interval > 0
    if (gClientCount > 0 && gKeepAliveSec > 0.0) {
        [[STHIDEventGenerator sharedGenerator] setKeepAliveInterval:gKeepAliveSec];
        TVLog(@"KeepAlive started with interval (%.3f sec)", gKeepAliveSec);
    }

    return RFB_CLIENT_ACCEPT;
}

#pragma mark - Clipboard Extension

static std::atomic<int> gClipboardSuppressSend(0); // >0 means suppress sending clipboard to clients

static void setXCutTextLatin1(char *str, int len, rfbClientPtr cl) {
    (void)cl;
    if (!str || len < 0)
        len = 0;

    TVLog(@"Clipboard: received client cut text (Latin-1) len=%d", len);
    NSData *data = [NSData dataWithBytes:str length:(NSUInteger)len];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!s)
        s = @"";

    dispatch_async(dispatch_get_main_queue(), ^{
        gClipboardSuppressSend.fetch_add(1, std::memory_order_relaxed);

        TVLog(@"Clipboard: applying client text to UIPasteboard (Latin-1), suppression now=%d",
              gClipboardSuppressSend.load(std::memory_order_relaxed));
        [[ClipboardManager sharedManager] setStringFromRemote:s];

        gClipboardSuppressSend.fetch_sub(1, std::memory_order_relaxed);
    });
}

static void setXCutTextUTF8(char *str, int len, rfbClientPtr cl) {
    (void)cl;
    if (!str || len < 0)
        len = 0;

    TVLog(@"Clipboard: received client cut text (UTF-8) len=%d", len);

    NSData *data = [NSData dataWithBytes:str length:(NSUInteger)len];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) {
        // Fallback try Latin-1 if UTF-8 decode fails
        s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        if (!s)
            s = @"";
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        gClipboardSuppressSend.fetch_add(1, std::memory_order_relaxed);

        TVLog(@"Clipboard: applying client text to UIPasteboard (UTF-8), suppression now=%d",
              gClipboardSuppressSend.load(std::memory_order_relaxed));
        [[ClipboardManager sharedManager] setStringFromRemote:s];

        gClipboardSuppressSend.fetch_sub(1, std::memory_order_relaxed);
    });
}

static void sendClipboardToClients(NSString *_Nullable text) {
    if (!gScreen) {
        TVLog(@"Clipboard: screen not initialized; skipping send");
        return;
    }

    if (!gClipboardEnabled) {
        TVLog(@"Clipboard: sync disabled; skipping send");
        return;
    }

    if (gClientCount <= 0) {
        TVLog(@"Clipboard: no connected clients; skipping send");
        return;
    }

    if (gClipboardSuppressSend.load(std::memory_order_relaxed) > 0) {
        TVLog(@"Clipboard: send suppressed (local set echo avoidance)");
        return; // suppressed (likely local set)
    }

    const char *utf8 = NULL;
    int utf8Len = 0;
    const char *latin1 = NULL;
    int latin1Len = 0;

    std::string utf8Buf;
    std::string latin1Buf;

    if (text) {
        NSData *utf8Data = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
        utf8Len = (int)utf8Data.length;
        utf8Buf.assign((const char *)utf8Data.bytes, (size_t)utf8Len);
        utf8 = utf8Len > 0 ? utf8Buf.data() : "";

        // Prepare best-effort Latin-1 fallback
        NSData *latin1Data = [text dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:YES];
        latin1Len = (int)latin1Data.length;
        latin1Buf.assign((const char *)latin1Data.bytes, (size_t)latin1Len);
        latin1 = latin1Len > 0 ? latin1Buf.data() : "";
    } else {
        // Empty/clear
        utf8 = "";
        utf8Len = 0;
        latin1 = "";
        latin1Len = 0;
    }

    TVLog(@"Clipboard: sending to clients (utf8Len=%d, latin1Len=%d, clients=%d)", utf8Len, latin1Len, gClientCount);
    rfbSendServerCutTextUTF8(gScreen, (char *)utf8, utf8Len, (char *)latin1, latin1Len);
}

#pragma mark - Server-Side Cursor

NS_INLINE void setupXCursor(rfbScreenInfoPtr screen) {
    int width = 13, height = 11;

    const char cursor[] = "             "
                          " xx       xx "
                          "  xx     xx  "
                          "   xx   xx   "
                          "    xx xx    "
                          "     xxx     "
                          "    xx xx    "
                          "   xx   xx   "
                          "  xx     xx  "
                          " xx       xx "
                          "             ";
    const char mask[] = "xxxx     xxxx"
                        "xxxx     xxxx"
                        " xxxx   xxxx "
                        "  xxxx xxxx  "
                        "   xxxxxxx   "
                        "    xxxxx    "
                        "   xxxxxxx   "
                        "  xxxx xxxx  "
                        " xxxx   xxxx "
                        "xxxx     xxxx"
                        "xxxx     xxxx";

    rfbCursorPtr c = rfbMakeXCursor(width, height, (char *)cursor, (char *)mask);
    if (!c)
        return;

    c->xhot = width / 2;
    c->yhot = height / 2;
    rfbSetCursor(screen, c);
}

NS_INLINE void setupAlphaCursor(rfbScreenInfoPtr screen, int mode) {
    int i, j;
    rfbCursorPtr c = screen ? screen->cursor : NULL;
    if (!c)
        return;

    int maskStride = (c->width + 7) / 8;

    if (c->alphaSource) {
        free(c->alphaSource);
        c->alphaSource = NULL;
    }
    if (mode == 0)
        return;

    c->alphaSource = (unsigned char *)malloc((size_t)c->width * (size_t)c->height);
    if (!c->alphaSource)
        return;

    for (j = 0; j < c->height; j++) {
        for (i = 0; i < c->width; i++) {
            unsigned char value = (unsigned char)(0x100 * i / c->width);
            rfbBool masked = (c->mask[(i / 8) + maskStride * j] << (i & 7)) & 0x80;
            c->alphaSource[i + c->width * j] = (unsigned char)(masked ? (mode == 1 ? value : 0xff - value) : 0);
        }
    }

    if (c->cleanupMask)
        free(c->mask);

    c->mask = (unsigned char *)rfbMakeMaskFromAlphaSource(c->width, c->height, c->alphaSource);
    c->cleanupMask = TRUE;
}

#pragma mark - Setups

static void setupGeometry(void) {
    NSDictionary *props = [[ScreenCapturer sharedCapturer] renderProperties];
    gSrcWidth = [props[(__bridge NSString *)kIOSurfaceWidth] intValue];
    gSrcHeight = [props[(__bridge NSString *)kIOSurfaceHeight] intValue];
    if (gSrcWidth <= 0 || gSrcHeight <= 0) {
        fprintf(stderr, "Failed to get screen dimensions from IOMobileFramebuffer\n");
        exit(EXIT_FAILURE);
    }

    // Apply output scaling if requested, then align (width multiple of 4)
    int tmpW = (gScale > 0.0 && gScale < 1.0) ? MAX(1, (int)floor((double)gSrcWidth * gScale)) : gSrcWidth;
    int tmpH = (gScale > 0.0 && gScale < 1.0) ? MAX(1, (int)floor((double)gSrcHeight * gScale)) : gSrcHeight;
    alignDimensions(tmpW, tmpH, &gWidth, &gHeight);
    gFBSize = (size_t)gWidth * (size_t)gHeight * (size_t)gBytesPerPixel;

    // Allocate double buffers (tightly packed BGRA/ARGB32)
    gFrontBuffer = calloc(1, gFBSize);
    gBackBuffer = calloc(1, gFBSize);
    if (!gFrontBuffer || !gBackBuffer) {
        fprintf(stderr, "Failed to allocate required frame buffers\n");
        exit(EXIT_FAILURE);
    }
}

// Map UIInterfaceOrientation to rotation quadrant (clockwise degrees/90)
NS_INLINE int rotationForOrientation(UIInterfaceOrientation o) {
    switch (o) {
    case UIInterfaceOrientationPortrait:
    default:
        return 0; // 0°
    case UIInterfaceOrientationPortraitUpsideDown:
        return 2; // 180°
    case UIInterfaceOrientationLandscapeLeft:
        return 1; // 90° CW
    case UIInterfaceOrientationLandscapeRight:
        return 3; // 270° CW
    }
}

static void setupOrientationObserver(void) {
    if (!gOrientationSyncEnabled)
        return;

    static FBSOrientationObserver *sObserver;
    sObserver = [[FBSOrientationObserver alloc] init];
    if (!sObserver) {
        fprintf(stderr, "Failed to create orientation observer instance\n");
        exit(EXIT_FAILURE);
    }

    // Set update handler
    void (^handler)(FBSOrientationUpdate *) = ^(FBSOrientationUpdate *update) {
        if (!update)
            return;

        UIInterfaceOrientation activeOrientation = [update orientation];

        // Note: Actual framebuffer rotation will be handled in the next step.
        gRotationQuad.store(rotationForOrientation(activeOrientation), std::memory_order_relaxed);

#if DEBUG
        NSUInteger seq = [update sequenceNumber];
        NSInteger direction = [update rotationDirection];
        NSTimeInterval dur = [update duration];
#endif
        TVLog(@"Orientation update: seq=%lu dir=%ld ori=%ld dur=%.3f", seq, direction, (long)activeOrientation, dur);
    };

    [sObserver setHandler:handler];

    // Prime current orientation if available
    UIInterfaceOrientation activeOrientation = [sObserver activeInterfaceOrientation];
    gRotationQuad.store(rotationForOrientation(activeOrientation), std::memory_order_relaxed);

    TVLog(@"Orientation observer registered (initial=%ld -> rotQ=%d)", (long)activeOrientation,
          gRotationQuad.load(std::memory_order_relaxed));
}

static void setupRfbScreen(int argc, const char *argv[]) {
    int argcCopy = argc; // rfbGetScreen may modify argc/argv
    char **argvCopy = (char **)argv;
    int bitsPerSample = 8;
    gScreen = rfbGetScreen(&argcCopy, argvCopy, gWidth, gHeight, bitsPerSample, 3, gBytesPerPixel);
    if (!gScreen) {
        fprintf(stderr, "Failed to create rfbScreenInfo with rfbGetScreen\n");
        exit(EXIT_FAILURE);
    }

    // BGRA (little-endian) layout
    gScreen->paddedWidthInBytes = gWidth * gBytesPerPixel;
    gScreen->serverFormat.redShift = bitsPerSample * 2;   // 16
    gScreen->serverFormat.greenShift = bitsPerSample * 1; // 8
    gScreen->serverFormat.blueShift = 0;
    gScreen->frameBuffer = (char *)gFrontBuffer;

    // Desktop name
    gScreen->desktopName = strdup([gDesktopName UTF8String]);

    // Server ports
    gScreen->port = gPort;
    gScreen->ipv6port = gPort;

    // Event handlers
    gScreen->newClientHook = newClientHook;
    gScreen->displayHook = displayHook;
    gScreen->displayFinishedHook = displayFinishedHook;
}

static void setupRfbEventHandlers(void) {
    gScreen->ptrAddEvent = ptrAddEvent;
    gScreen->kbdAddEvent = kbdAddEvent;
}

static void setupRfbClassicAuthentication(void) {
    // Enable classic VNC authentication if environment variables are provided
    const char *envPwd = getenv("TROLLVNC_PASSWORD");
    const char *envViewPwd = getenv("TROLLVNC_VIEWONLY_PASSWORD");

    int fullCount = (envPwd && *envPwd) ? 1 : 0;
    int viewCount = (envViewPwd && *envViewPwd) ? 1 : 0;
    if (fullCount + viewCount > 0) {
        // Vector size = number of passwords + 1 for NULL terminator
        int vecCount = fullCount + viewCount + 1;
        gAuthPasswdVec = (char **)calloc((size_t)vecCount, sizeof(char *));
        if (!gAuthPasswdVec) {
            fprintf(stderr, "Failed to allocate memory for password vector\n");
            exit(EXIT_FAILURE);
        }

        int idx = 0;
        if (fullCount) {
            gAuthPasswdStr = strdup(envPwd);
            if (!gAuthPasswdStr) {
                fprintf(stderr, "Failed to allocate memory for full-access password\n");
                exit(EXIT_FAILURE);
            }
            gAuthPasswdVec[idx++] = gAuthPasswdStr;
        }

        if (viewCount) {
            gAuthViewOnlyPasswdStr = strdup(envViewPwd);
            if (!gAuthViewOnlyPasswdStr) {
                fprintf(stderr, "Failed to allocate memory for view-only password\n");
                exit(EXIT_FAILURE);
            }
            gAuthPasswdVec[idx++] = gAuthViewOnlyPasswdStr;
        }

        gAuthPasswdVec[idx] = NULL; // NULL-terminated array
        gScreen->authPasswdData = (void *)gAuthPasswdVec;

        // Index of first view-only password = number of full-access passwords
        // From that index onward (1-based in description, 0-based in array) are view-only.
        gScreen->authPasswdFirstViewOnly = fullCount;
        gScreen->passwordCheck = rfbCheckPasswordByList;

        TVLog(@"Classic VNC authentication enabled via env: full=%d, view-only=%d", fullCount, viewCount);
    }
}

static void setupRfbCutTextHandlers(void) {
    // client->server sync
    if (gClipboardEnabled) {
        gScreen->setXCutText = setXCutTextLatin1;
        gScreen->setXCutTextUTF8 = setXCutTextUTF8;
        TVLog(@"Clipboard: client->server handlers registered (enabled)");
    } else {
        gScreen->setXCutText = NULL;
        gScreen->setXCutTextUTF8 = NULL;
        TVLog(@"Clipboard: client->server handlers not registered (disabled)");
    }
}

static void setupRfbServerSideCursor(void) {
    if (gCursorEnabled) {
        setupXCursor(gScreen);
        setupAlphaCursor(gScreen, 0);
        TVLog(@"Cursor: XCursor + alpha mode=2 enabled");
    } else {
        gScreen->cursor = NULL;
        TVLog(@"Cursor: disabled (default; enable with -U on)");
    }
}

static void setupRfbHttpServer(void) {
    // Built-in HTTP server settings (see rfb.h http* fields)
    gScreen->httpEnableProxyConnect = TRUE; // always allow CONNECT if HTTP is enabled
    if (gHttpPort > 0) {
        gScreen->httpPort = gHttpPort; // enable HTTP on specified port
        gScreen->http6Port = gHttpPort;
        if (gHttpDirOverride) {
            // Use override absolute path
            gScreen->httpDir = strdup(gHttpDirOverride);
            TVLog(@"HTTP server config: port=%d, dir=%s (override), proxyConnect=YES", gHttpPort, gHttpDirOverride);
        } else {
            // Compute httpDir relative to executable: ../share/trollvnc/webclients
            do {
                // Resolve executable path
                uint32_t sz = 0;
                _NSGetExecutablePath(NULL, &sz); // query size
                char *exeBuf = (char *)malloc(sz > 0 ? sz : 1024);
                if (!exeBuf)
                    break;
                if (_NSGetExecutablePath(exeBuf, &sz) != 0) {
                    // Fallback: leave exeBuf as-is
                }

                // Canonicalize
                char realBuf[PATH_MAX];
                const char *exePath = realpath(exeBuf, realBuf) ? realBuf : exeBuf;
                NSString *exe = [NSString stringWithUTF8String:exePath ? exePath : ""];
                NSString *exeDir = [exe stringByDeletingLastPathComponent];
                NSString *webRel = @"../share/trollvnc/webclients";
                NSString *webPath = [[exeDir stringByAppendingPathComponent:webRel] stringByStandardizingPath];
                const char *fs = [webPath fileSystemRepresentation];
                if (fs && *fs) {
                    gScreen->httpDir = strdup(fs);
                    TVLog(@"HTTP server config: port=%d, dir=%@, proxyConnect=YES", gHttpPort, webPath);
                }

                free(exeBuf);
            } while (0);
        }
    } else {
        gScreen->httpPort = 0;   // disabled
        gScreen->httpDir = NULL; // do not set dir to avoid default startup
    }

    // SSL certificate and key (optional)
    if (gSslCertPath && *gSslCertPath) {
        if (gScreen->sslcertfile)
            free(gScreen->sslcertfile);
        gScreen->sslcertfile = strdup(gSslCertPath);
    }
    if (gSslKeyPath && *gSslKeyPath) {
        if (gScreen->sslkeyfile)
            free(gScreen->sslkeyfile);
        gScreen->sslkeyfile = strdup(gSslKeyPath);
    }
}

static void initializeAndRunRfbServer(void) {
    rfbInitServer(gScreen);
    TVLog(@"VNC server initialized on port %d, %dx%d, name '%@'", gPort, gWidth, gHeight, gDesktopName);

    // Run VNC in background thread
    rfbRunEventLoop(gScreen, 40000, TRUE);
}

static void handleSignal(int signum) {
    (void)signum;
    TVLog(@"Signal %d received", signum);

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

static void prepareClipboardManager(void) {
    // server->client sync; start/stop tied to client presence
    if (gClipboardEnabled) {
        [[ClipboardManager sharedManager] setOnChange:^(NSString *_Nullable text) {
            // If we’re in suppression (coming from client->server), do nothing
            if (gClipboardSuppressSend.load(std::memory_order_relaxed) > 0)
                return;
            sendClipboardToClients(text);
        }];
    } else {
        [[ClipboardManager sharedManager] setOnChange:nil];
    }
}

static void prepareScreenCapturer(void) {
    // Apply preferred frame rate (if provided)
    if (gFpsMin > 0 || gFpsPref > 0 || gFpsMax > 0) {
        TVLog(@"Applying preferred FPS to ScreenCapturer: min=%d pref=%d max=%d", gFpsMin, gFpsPref, gFpsMax);
        [[ScreenCapturer sharedCapturer] setPreferredFrameRateWithMin:gFpsMin preferred:gFpsPref max:gFpsMax];
    }

    gFrameHandler = ^(CMSampleBufferRef _Nonnull sampleBuffer) {
        handleFramebuffer(sampleBuffer);
    };
}

#pragma mark - Main Procedure

static void cleanupAndExit(int code) {
    if (gScreen) {
        rfbShutdownServer(gScreen, YES);
        rfbScreenCleanup(gScreen);
        gScreen = NULL;
    }

    // There’s no need to free other resources because we’re going to exit the process. Yay!
    exit(code);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        parseCLI(argc, argv);

        setupGeometry();
        setupOrientationObserver();

        setupRfbScreen(argc, argv);
        setupRfbEventHandlers();
        setupRfbClassicAuthentication();
        setupRfbCutTextHandlers();
        setupRfbServerSideCursor();
        setupRfbHttpServer();

        initializeAndRunRfbServer();
        initializeTilingOrReset();
        installSignalHandlers();

        prepareClipboardManager();
        prepareScreenCapturer();
    }

    CFRunLoopRun();
    cleanupAndExit(EXIT_SUCCESS);

    return EXIT_SUCCESS;
}