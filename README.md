# TrollVNC

TrollVNC is a VNC server for iOS devices, allowing remote access and control of the device's screen.

## Usage

Run on device:

```sh
trollvncserver -p 5901 -n "My iPhone" [options]
```

Options:

- -p port   TCP port for VNC (default: 5901)
- -n name   Desktop name shown to clients (default: TrollVNC)
- -v        View-only (ignore input)
- -a        Enable non-blocking swap (may cause tearing). Default off.
- -t size   Tile size for dirty-detection in pixels (8..128, default: 32)
- -P pct    Fullscreen fallback threshold percent (0..100, default: 30; 0 disables dirty detection)
- -R max    Max dirty rects before collapsing to a bounding box (default: 256)
- -d sec    Defer update window in seconds to coalesce changes (0..0.5, default: 0.015)
- -Q n      Max in-flight updates before dropping new frames (0..8, default: 1; 0 disables dropping)
- -s scale  Output scale factor 0<s<=1 (default: 1.0; 1 means no scaling)
- -W px     Wheel step in pixels per tick (default: 48)
- -w k=v,.. Wheel tuning: step,coalesce,max,clamp,amp,cap,minratio,durbase,durk,durmin,durmax
- -N        Natural scroll direction (invert wheel delta)
- -M scheme Modifier mapping: std|altcmd (default: std)
- -F spec   Preferred frame rate: single fps, min-max, or min:pref:max. iOS15+ uses a range; iOS14 uses the max.
- -K        Log keyboard events (keysym -> mapping) to stderr
- -h        Show built-in help and LibVNCServer usage

Notes:

- Capture starts only when at least one client is connected, and stops when the last disconnects.
- When -a is enabled, we try a non-blocking swap to reduce contention; if it fails, we copy only dirty rectangles to the front buffer to minimize tearing and bandwidth.
- Dirty rectangles are detected via per-tile FNV-1a hashing. If too many tiles change (>= threshold), we fallback to full-screen updates for efficiency. Set -P 0 to disable hashing/dirty detection entirely and always send full-screen updates.
- Scaling uses Accelerate/vImage for high-quality resampling. Tiling/hash/dirty detection runs on the scaled output to reduce bandwidth and CPU.

## Performance Tips

Tuning knobs and how they trade off latency, bandwidth, and CPU usage:

- -s scale: Output resolution scale. Smaller scale cuts bandwidth and encoding cost the most. For text-heavy UIs, 0.66~0.75 often reads better than 0.5.
- -d sec: Defer window. Larger values coalesce more updates (less CPU/bandwidth) at the cost of added latency. Typical range: 0.005–0.030.
- -Q n: Max in-flight encodes. Higher values increase throughput but can raise CPU and memory; 0 disables dropping and can increase latency when encoders are slow.
- -t size: Tile size for dirty detection. Smaller tiles detect fine-grained changes but raise hashing/rect overhead. 32 is a good default; 64 reduces CPU on slower devices.
- -P pct: Threshold to switch to full-screen updates. 25–40 is a practical range; higher values favor rect updates longer.
- -R max: Rect cap before collapsing to a bounding box. Too high increases RFB overhead; 128–512 is often sufficient.
- -a: Non-blocking swap. Can reduce contention and stutter under load but may occasionally increase tearing; leave off for maximal visual stability.

### Wheel/Scroll Tuning

The scroll wheel is emulated with short drags. Fast wheel motion becomes one longer flick; slow motion becomes short drags. You can tune its feel at runtime:

- -W px: Base pixels per wheel tick (default 48). Larger = faster scrolls.
- -w k=v,... keys:
  - step: same as -W (pixels)
  - coalesce: coalescing window in seconds (default 0.03, 0..0.5)
  - max: base max distance per gesture before clamp (default 192)
  - clamp: absolute clamp factor, final max distance = clamp × max (default 2.5)
  - amp: velocity amplification coefficient for fast scrolls (default 0.18)
  - cap: max extra amplification (default 0.75)
  - minratio: minimum effective distance vs step for tiny scrolls (default 0.35)
  - durbase: gesture duration base in seconds (default 0.05)
  - durk: gesture duration factor applied to sqrt(distance) (default 0.00016)
  - durmin: min gesture duration (default 0.05)
  - durmax: max gesture duration (default 0.14)
  - natural: 1 to enable natural direction, 0 to disable

Examples:

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

### Frame Rate Control

Use -F to set the CADisplayLink frame rate:

- Single value: `-F 60`
- Range: `-F 30-60`
- Full range with preferred: `-F 30:60:120`

Notes:

- On iOS 15+, the full range is applied via preferredFrameRateRange.
- On iOS 14, only preferredFramesPerSecond is available, so the max (or preferred if provided) is used.

Notes:

- Scaling happens before dirty detection; tile size applies to the scaled frame. Effective tile size in source pixels ≈ t / scale.
- With -Q 0, frames are never dropped. If the client or network is slow, input-to-display latency can grow.
- On older devices, prefer lowering -s and increasing -t to reduce CPU and memory bandwidth.

## Authentication

Classic VNC authentication can be enabled via environment variables:

- TROLLVNC_PASSWORD: full-access password. Enables VNC auth when set.
- TROLLVNC_VIEWONLY_PASSWORD: optional view-only password. When present, clients authenticating with this password can view but cannot send input.

Semantics:

- Passwords are stored in a NULL-terminated list as [full..., view-only...]. The index of the first view-only password equals the number of full-access passwords.
- Classic VNC only uses the first 8 characters of each password.

Examples (zsh):

```sh
export TROLLVNC_PASSWORD=editpass
export TROLLVNC_VIEWONLY_PASSWORD=viewpass   # optional
trollvncserver -p 5901 -n "My iPhone"
```

Notes:

- -v forces global view-only regardless of password. View-only password applies per client.
- Environment variables may be visible to the process environment; consider using a secure launcher if needed.

## Preset Examples

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

Optional: add -a to any profile if you observe occasional stalls due to encoder contention; remove it if tearing is noticeable:

```sh
trollvncserver ... -a
```

## Build Dependencies

OpenSSL is not necessary for building VNC server because it does not use any SSL/TLS features. See: <https://github.com/Lessica/BuildVNCServer>

## License

TrollVNC is licensed under the GPLv2 License. See the COPYING file for more information.
