# TrollVNC

TrollVNC is a VNC server for iOS devices, allowing remote access and control of the device’s screen.

<img width="763" alt="screenshot tiny" src="https://github.com/user-attachments/assets/2d2cd457-a3d2-475a-b391-e3232d747f48" />

## Usage

1. Download “TrollVNC” from Releases and install it on your iOS device.
2. Configure the VNC server settings from “Settings” → “TrollVNC” or the standalone “TrollVNC” app as needed.
3. Or, run the following command on iOS device or simulator:

```sh
trollvncserver -p 5901 -n "My iPhone" [options]
```

### Options

Basic:

- `-p port`   TCP port for VNC (default: `5901`)
- `-n name`   Desktop name shown to clients (default: `TrollVNC`)
- `-v`        View-only (ignore input)
- `-A sec`    Keep-alive interval to prevent device sleep by sending harmless dummy key events; only active while at least one client is connected (`15..86400`, `0` disables, default: `0`)
- `-C on|off` Clipboard sync (default: `on`)

Display/Performance:

- `-s scale`  Output scale factor (`0 < s <= 1`, default: `1.0`; `1` means no scaling)
- `-F spec`   Frame rate: single `fps`, range `min-max`, or full `min:pref:max`; on iOS 15+ a range is applied, on iOS 14 the max (or preferred) is used
- `-d sec`    Defer update window in seconds to coalesce changes (`0..0.5`, default: `0.015`)
- `-Q n`      Max in-flight updates before dropping new frames (`0..8`, default: `2`; `0` disables dropping)

Dirty detection:

- `-t size`   Tile size for dirty-detection in pixels (`8..128`, default: `32`)
- `-P pct`    Fullscreen fallback threshold percent (`0..100`, default: `0`; `0` disables dirty detection entirely)
- `-R max`    Max dirty rects before collapsing to a bounding box (default: `256`)
- `-a`        Enable non-blocking swap (may cause tearing).

Scroll/Input:

- `-W px`     Wheel step in pixels per tick (`0` disables, default: `48`)
- `-w k=v,..` Wheel tuning keys: `step,coalesce,max,clamp,amp,cap,minratio,durbase,durk,durmin,durmax`
- `-N`        Natural scroll direction (invert wheel delta)
- `-M scheme` Modifier mapping: `std|altcmd` (default: `std`)
- `-K`        Log keyboard events (keysym -> mapping) to stderr

Accessibility:

- `-E on|off` Enable AssistiveTouch auto-activation (default: `off`)

Cursor & Rotation:

- `-U on|off` Enable server-side cursor overlay (default: `off`)
- `-O on|off` Sync UI orientation and rotate output (default: `off`)

HTTP/WebSockets:

- `-H port`   Enable built-in HTTP server on port (`0` disables; default `0`)
- `-D path`   Absolute path for HTTP document root
- `-e file`   Path to SSL certificate file
- `-k file`   Path to SSL private key file

Discovery:

- `-B on|off` Enable Bonjour/mDNS advertisement for auto-discovery by viewers on the local network (default: `on`)

Logging:

- `-V`        Enable verbose logging (debug only)

Help:

- `-h`        Show built-in help message

Notes:

- Capture starts only when at least one client is connected, and stops when the last disconnects.
- You may want to use `-M altcmd` on macOS clients.

### Key Input Mapping

Mouse:

- Left button: single-finger touch. Hold to drag; move updates while held.
- Right button: iOS Home/Menu (Consumer: Menu). Press = short press; hold ≈ long press. Release ends the press.
- Middle button: Power button (Consumer: Power). Press = short press; hold ≈ long press. Release ends the press.
- Wheel: translated into short drags with coalescing/velocity; see “Wheel/Scroll Tuning”.

Keyboard:

- Standard ASCII keys, Return/Tab/Backspace/Delete, arrows, Home/End/PageUp/PageDown, and function keys F1..F24 are
  sent as HID keyboard usages.
- Modifier mapping (`-M`):
  - `std` (default): Alt -> Option; Meta/Super -> Command.
  - `altcmd`: Alt -> Command; Meta -> Option; Super -> Command.
- Media/consumer keys (when the client sends XF86 keysyms):
  - Brightness Up/Down -> display brightness increment/decrement
  - Volume Up/Down/Mute -> volume increment/decrement/mute
  - Previous / Play-Pause / Next -> previous track / toggle play-pause / next track

Notes:

- “Home/Menu” is generated via the Consumer Menu usage; on devices without a physical Home button it performs the Home action.
- Double/triple press of Power/Home are not synthesized automatically from mouse clicks; hold the button to simulate long-press when needed.
- Touch, scroll, and button mappings respect the current rotation when `-O on` is used.

AssistiveTouch auto-activation (`-E on`):

- When the first client connects, TrollVNC enables AssistiveTouch if it’s currently off; when the last client disconnects,
  it restores the previous state (disables it only if TrollVNC enabled it).
- Applies on device builds; no-op on the simulator.

## Performance Tips

Quick guidance on key trade-offs (latency vs. bandwidth vs. CPU/battery):

- `-s scale`: Biggest lever for bandwidth and encoder CPU. Start at `0.66–0.75` for text-heavy UIs; use `0.5` for tight links or slow networks; `1.0` for pixel-perfect.
- `-F spec`: Cap preferred frame rate to balance smoothness and battery. `30–60` is a sensible range; on 120 Hz devices, `60` often suffices. On iOS 14 the max (or preferred if provided) value is used.
- `-d sec`: Coalesce updates. Larger values lower CPU/bitrate but add latency. Typical range `0.005–0.030`; interactive UIs prefer `≤ 0.015`.
- `-Q n`: Throughput vs. latency backpressure. `1–2` recommended. `0` disables dropping and can grow latency when encoders are slow.
- `-t size`: Dirty-detection tile size. `32` default; `64` cuts hashing/rect overhead on slower devices; `16` (or `8`) captures finer UI details at higher CPU cost.
- `-P pct`: Fullscreen fallback threshold. Practical `25–40`; higher values stick to rect updates longer. `0` disables dirty detection (always fullscreen).
- `-R max`: Rect cap before collapsing to a bounding box. `128–512` common; too high increases RFB overhead.
- `-a`: Non-blocking swap. Can reduce stalls/contension; may introduce tearing. Try if you see occasional stalls; leave off for maximal visual stability. If a non-blocking swap cannot lock clients, TrollVNC falls back to copying only dirty rectangles to the front buffer to minimize tearing and bandwidth.

Notes:

- Scaling happens before dirty detection; tile size applies to the scaled frame. Effective tile size in source pixels ≈ t / scale.
- With `-Q 0`, frames are never dropped. If the client or network is slow, input-to-display latency can grow.
- On older devices, prefer lowering `-s` and increasing `-t` to reduce CPU and memory bandwidth.

### Preset Examples

By default, dirty detection is **disabled** because it usually has a high CPU cost. You can enable it with `-P` to set a fullscreen fallback threshold.

Low-latency interactive (LAN):

```sh
trollvncserver -p 5901 -n "My iPhone" -s 0.75 -d 0.008 -Q 1 -t 32 -P 35 -R 512
```

Battery/bandwidth saver (cellular/WAN):

```sh
trollvncserver -p 5901 -n "My iPhone" -s 0.5 -d 0.025 -Q 2 -t 64 -P 50 -R 128
```

High quality on fast LAN:

```sh
trollvncserver -p 5901 -n "My iPhone" -s 1.0 -d 0.012 -Q 2 -t 32 -P 30 -R 512
```

Choppy network (high RTT/loss):

```sh
trollvncserver -p 5901 -n "My iPhone" -s 0.66 -d 0.035 -Q 1 -t 64 -P 60 -R 128
```

Older devices (CPU-limited):

```sh
trollvncserver -p 5901 -n "My iPhone" -s 0.5 -d 0.02 -Q 1 -t 64 -P 40 -R 256
```

Optional: add `-a` to any profile if you observe occasional stalls due to encoder contention; remove it if tearing is noticeable:

```sh
trollvncserver ... -a
```

### Frame Rate Control

Use `-F` to set the `CADisplayLink` frame rate:

- Single value: `-F 60`
- Range: `-F 30-60`
- Full range with preferred: `-F 30:60:120`

Notes:

- On iOS 15+, the full range is applied via `preferredFrameRateRange`.
- On iOS 14, only `preferredFramesPerSecond` is available, so the max (or preferred if provided) is used.

### Keep-Alive (Prevent Sleep)

Use `-A` to periodically send a harmless dummy key event to keep the device awake while clients are connected.

- Active only when at least one client is connected; automatically stops when the last client disconnects.
- Set `-A 0` (or omit) to disable. Shorter intervals may increase battery usage.

## Wheel/Scroll Tuning

The scroll wheel is emulated with short drags. Fast wheel motion becomes one longer flick; slow motion becomes short drags. You can tune its feel at runtime:

- `-W px`: Base pixels per wheel tick (`0` disables, default `48`). Larger = faster scrolls.
- `-w k=v,...` keys:
  - `step`: same as `-W` (pixels)
  - `coalesce`: coalescing window in seconds (default `0.03`, `0..0.5`)
  - `max`: base max distance per gesture before clamp (default `192`)
  - `clamp`: absolute clamp factor, final max distance = clamp × max (default `2.5`)
  - `amp`: velocity amplification coefficient for fast scrolls (default `0.18`)
  - `cap`: max extra amplification (default `0.75`)
  - `minratio`: minimum effective distance vs step for tiny scrolls (default `0.35`)
  - `durbase`: gesture duration base in seconds (default `0.05`)
  - `durk`: gesture duration factor applied to sqrt(distance) (default `0.00016`)
  - `durmin`: min gesture duration (default `0.05`)
  - `durmax`: max gesture duration (default `0.14`)
  - `natural`: `1` to enable natural direction, `0` to disable

### Examples

Smooth and slow:

```sh
trollvncserver ... -W 32 -w minratio=0.3,durbase=0.06,durmax=0.16
```

Fast long scrolls:

```sh
trollvncserver ... -W 64 -w amp=0.25,cap=1.0,max=256,clamp=3.0
```

More sensitive small scrolls:

```sh
trollvncserver ... -w minratio=0.5,durbase=0.055
```

Disable wheel entirely:

```sh
trollvncserver ... -W 0
```

## Clipboard Sync

_I’ve tested and confirmed only ISO-8859-1 (Latin-1) encoding is supported now._

- UTF-8 clipboard sync is enabled by default; fallbacks to Latin-1 for legacy clients where needed.
- Starts when the first client connects and stops when the last disconnects.
- Disable it with `-C off` if not desired.

## Rotate / Orientation

When `-O on` is set, TrollVNC tracks iOS interface orientation and rotates the outgoing framebuffer to match (0°, 90°, 180°, 270°). Touch and scroll input are mapped into the device coordinate space with the correct axis and direction in all orientations.

Pipeline overview (per frame):

1) Capture portrait buffer from `ScreenCapturer`.
2) Rotate with Accelerate/vImage (90/180/270) into a tight ARGB buffer.
3) Scale to the server output size (if `-s < 1.0`), reusing a persistent vImage temp buffer to reduce allocations.
4) Width is rounded up to a multiple of 4 bytes per pixel row to satisfy encoders/clients; height is adjusted to preserve aspect ratio.
5) Framebuffer is resized via LibVNCServer when geometry changes; width/height and pixel format are kept consistent (BGRA little-endian).
6) Dirty detection (if enabled via `-P > 0`) runs on the rotated+scaled back buffer.

Dirty detection and rotation:

- On an orientation change, TrollVNC performs a one-time full-screen update and clears pending tile state to establish a clean baseline.
- Tile/hash tables are reinitialized on any geometry change (e.g., 90°/270° or scale changes).
- Subsequent frames use normal tile hashing and dirty rectangles again.
- Set `-P 0` to disable dirty detection entirely and always send full frames.

Input mapping:

- Touch coordinates are transformed from the VNC framebuffer space back into the device’s portrait space, inverting the current rotation.
- The scroll wheel is emulated with short drags; when rotated, the gesture axis and direction are remapped (e.g., in landscape, vertical wheel becomes a horizontal drag). `-N` still toggles natural direction.

Examples:

```sh
# Enable rotation sync and keep dirty detection enabled with a reasonable threshold
trollvncserver -O on -P 35 -t 32 -R 512

# Rotation sync with full frames (dirty detection disabled)
trollvncserver -O on -P 0
```

## Server-Side Cursor

iOS does not present a native on-screen cursor in this setup. TrollVNC does not draw a cursor by default; most VNC viewers render their own pointer. If your viewer expects the server to render a cursor, enable it with `-U on`.

Details:

- Overlay style: a simple “X” cursor shape with centered hotspot. Alpha is disabled to keep the cursor crisp.
- Pros: visible even if the client does not draw its own cursor.
- Cons: may show two cursors if the client also renders one. Keep it off unless needed.

## Authentication

Classic VNC authentication can be enabled via environment variables:

- `TROLLVNC_PASSWORD`: full-access password. Enables VNC auth when set.
- `TROLLVNC_VIEWONLY_PASSWORD`: optional view-only password. When present, clients authenticating with this password can view but cannot send input.

Semantics:

- Passwords are stored in a NULL-terminated list as `[full..., view-only...]`. The index of the first view-only password equals the number of full-access passwords.
- Classic VNC only uses the first 8 characters of each password.

Examples (zsh):

```sh
export TROLLVNC_PASSWORD=editpass
export TROLLVNC_VIEWONLY_PASSWORD=viewpass   # optional
trollvncserver -p 5901 -n "My iPhone"
```

Notes:

- `-v` forces global view-only regardless of password. View-only password applies per client.
- You must set a password if you’re using the built-in VNC client of macOS.
- Environment variables may be visible to the process environment; consider using a secure launcher if needed.

## HTTP / WebSockets

TrollVNC can start LibVNCServer’s built-in HTTP server to serve a browser-based VNC client ([noVNC](https://github.com/novnc/noVNC)).

Behavior:

- When `-H` is non-zero, the HTTP server listens on that port.
- If `-D` is provided, its absolute path is used as `httpDir`.
- If `-D` is omitted, TrollVNC derives a default `httpDir` relative to the executable `../share/trollvnc/webclients`.
- HTTP proxy CONNECT is enabled to support certain viewer flows.

Examples:

```sh
# Enable web client on port 5801 using the default web root
trollvncserver -p 5901 -H 5801

# Enable web client on port 8081 with a custom web root
trollvncserver -p 5901 -H 8081 -D /var/www/trollvnc/webclients
```

Notes:

- Ensure the web root contains the required client assets.
- If the directory is missing or incomplete, the HTTP server may start but won’t serve a functional client.

### Using Secure WebSockets

You can serve the web client over HTTPS/WSS by providing an SSL certificate and key via `-e` and `-k`.

What you need:

- A certificate (`cert.pem`) and private key (`key.pem`) that your browser will accept.
- The HTTP server enabled on some port with `-H`.

Quick start with a local CA (minica):

```sh
# 1) Install minica (macOS):
brew install minica

# 2) Create a host cert for your device IP or DNS name
minica -ip-addresses "192.168.2.100"
# This produces a CA (minica.pem) and a host folder (e.g., 192.168.2.100/) with cert.pem and key.pem

# 3) Trust the CA in your browser/OS by importing minica.pem (Authorities/Trusted Roots)
#    Without this, the browser will warn about an untrusted certificate.

# 4) Copy the host cert and key to the device (pick any readable path)
scp -r 192.168.2.100 root@192.168.2.100:/usr/share/trollvnc/ssl/

# 5) Start TrollVNC with HTTPS/WSS enabled
trollvncserver -p 5901 -H 5801 \
  -e /usr/share/trollvnc/ssl/192.168.2.100/cert.pem \
  -k /usr/share/trollvnc/ssl/192.168.2.100/key.pem
```

Connect:

- Open `https://192.168.2.100:5801/` in your browser.
- Use the bundled web client page to connect to the VNC server.

Notes:

- Certificates must match what the browser connects to (IP or hostname).
- Self-signed setups require trusting the CA (minica.pem) or the specific certificate.

## Auto-Discovery (Bonjour/mDNS)

TrollVNC can advertise itself on the local network via Bonjour/mDNS so compatible viewers can discover it without typing an IP/port.

What it does:

- Publishes an mDNS service of type `_rfb._tcp` (the standard for VNC).
- Uses the desktop name from `-n` as the service name and the VNC port from `-p`.
- Starts the advertisement when the server starts and stops it on exit.

How to control it:

- Command line: `-B on|off` (default: `on`). Example to disable: `trollvncserver ... -B off`
- Preferences app: toggle “Enable Auto-Discovery” in TrollVNC settings.

Client discovery tips:

- Many VNC apps (and network scanners) list `_rfb._tcp` services automatically on the LAN.
- If you’re using the built-in HTTP client (noVNC), Bonjour is unrelated to WebSockets; it only helps native VNC viewers find the TCP server.

Troubleshooting:

- Ensure the device and client are on the same subnet and that multicast (mDNS) is not filtered by your Wi‑Fi/AP.
- If discovery doesn’t show up, you can still connect manually using the device IP and port shown in the app or logs.

## Build Dependencies

See: <https://github.com/Lessica/BuildVNCServer>

## Acknowledgements

- [libvncserver](https://github.com/LibVNC/libvncserver)
- [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo)
- [libpng](https://github.com/pnggroup/libpng)
- [OpenSSL](https://github.com/openssl/openssl)
- [Cyrus SASL](https://github.com/cyrusimap/cyrus-sasl)
- The majority of the main program `src/trollvncserver.mm` was written/generated by GitHub Copilot (GPT-5).

## License

TrollVNC is licensed under the GPLv2 License. See the COPYING file for more information.
