# TrollVNC

TrollVNC is a VNC server for iOS devices, allowing remote access and control of the device's screen.

## Build Dependencies

OpenSSL is not necessary for building VNC server because it does not use any SSL/TLS features. See: <https://github.com/Lessica/BuildVNCServer>

## License

TrollVNC is licensed under the GPLv2 License. See the COPYING file for more information.

## Usage

Run on device:

```sh
trollvncserver -p 5901 -n "My iPhone" [options]
```

Options:

- -p port   TCP port for VNC (default: 5900)
- -n name   Desktop name shown to clients (default: TrollVNC)
- -v        View-only (ignore input)
- -a        Enable non-blocking swap (may cause tearing). Default off.
- -t size   Tile size for dirty-detection in pixels (8..128, default: 32)
- -P pct    Fullscreen fallback threshold percent (1..100, default: 30)
- -R max    Max dirty rects before collapsing to a bounding box (default: 256)
- -d sec    Defer update window in seconds to coalesce changes (0..0.5, default: 0.015)
- -h        Show built-in help and LibVNCServer usage

Notes:

- Capture starts only when at least one client is connected, and stops when the last disconnects.
- When -a is enabled, we try a non-blocking swap to reduce contention; if it fails, we copy only dirty rectangles to the front buffer to minimize tearing and bandwidth.
- Dirty rectangles are detected via per-tile FNV-1a hashing. If too many tiles change (>= threshold), we fallback to full-screen updates for efficiency.
