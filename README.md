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
- -P pct    Fullscreen fallback threshold percent (1..100, default: 30)
- -R max    Max dirty rects before collapsing to a bounding box (default: 256)
- -d sec    Defer update window in seconds to coalesce changes (0..0.5, default: 0.015)
- -Q n      Max in-flight updates before dropping new frames (0..8, default: 1; 0 disables dropping)
- -s scale  Output scale factor 0<s<=1 (default: 1.0; 1 means no scaling)
- -h        Show built-in help and LibVNCServer usage

Notes:

- Capture starts only when at least one client is connected, and stops when the last disconnects.
- When -a is enabled, we try a non-blocking swap to reduce contention; if it fails, we copy only dirty rectangles to the front buffer to minimize tearing and bandwidth.
- Dirty rectangles are detected via per-tile FNV-1a hashing. If too many tiles change (>= threshold), we fallback to full-screen updates for efficiency.
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

Notes:

- Scaling happens before dirty detection; tile size applies to the scaled frame. Effective tile size in source pixels ≈ t / scale.
- With -Q 0, frames are never dropped. If the client or network is slow, input-to-display latency can grow.
- On older devices, prefer lowering -s and increasing -t to reduce CPU and memory bandwidth.

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
