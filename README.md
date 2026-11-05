# NestCast

**NestCast** is a lightweight, native macOS Menu Bar application that discovers and streams audio to **Google Nest Mini**, **Google Home**, and Chromecast Audio speakers directly over Wi-Fi — completely bypassing Bluetooth.

Developed and maintained by **[@gpsurya](https://github.com/gpsurya)**.

---

## Highlights

* **Pure Wi-Fi Streaming (No Bluetooth):** Zero Bluetooth pairing headaches, no compression artifacts, and no 10-meter room range limitations.
* **Menu Bar Status Dropdown:** Lives unobtrusively in your macOS status bar (`LSUIElement`). Click the icon to view all active speakers on your home network.
* **Instant Auto-Discovery:** Discovers your Google Nest Mini and Chromecast devices via mDNS (`_googlecast._tcp.local`) using native Swift `NetService` resolution.
* **Reverse-Engineered Cast V2 Wire Protocol:** Directly speaks Google Cast V2 protobuf framing over TLS (port `8009`) without needing bloated third-party SDKs.
* **Live Volume Control:** Real-time volume slider synced directly to your Google Nest Mini.
* **System Audio Bridge Mode:** Includes a 1-click toggle to expose all your Google Nest speakers as native **AirPlay** audio sinks in macOS Control Center, allowing system-wide audio (Spotify, Apple Music, YouTube, Safari, Zoom) to stream directly to your Nest Mini.
* **Built-in Self-Contained Test Suite:** Verified packet encoding, WAV chime generation, and network discovery without external dependencies.

---

## Architecture & Reverse-Engineered Cast Stack

```
┌────────────────────────────────────────────────────────┐
│                   NestCast (Mac App)                   │
│                                                        │
│  [MenuBarExtra (SwiftUI Popover)]                      │
│          │                                             │
│          ├── CastDiscovery (mDNS _googlecast._tcp)     │
│          │     └── Extracts "fn" (Friendly Name)       │
│          │                                             │
│          ├── AudioStreamServer (NWListener :8088)      │
│          │     └── Serves HTTP live PCM/WAV chunks     │
│          │                                             │
│          ├── CastProtocol (Cast V2 TLS Socket :8009)   │
│          │     ├── urn:x-cast:tp.connection -> CONNECT │
│          │     ├── urn:x-cast:tp.heartbeat  -> PING    │
│          │     ├── urn:x-cast:receiver      -> LAUNCH  │
│          │     └── urn:x-cast:media         -> LOAD    │
│          │                                             │
│          └── AirCastBridge (Background Daemon)         │
│                └── Virtual AirPlay sink for macOS      │
└──────────────────────────┬─────────────────────────────┘
                           │ Wi-Fi LAN
                           ▼
┌────────────────────────────────────────────────────────┐
│                   Google Nest Mini                     │
│                                                        │
│  • Discovered as "Surya speaker" (:8009)               │
│  • Boots Default Media Receiver (CC1AD845)             │
│  • Pulls & plays audio stream from Mac                 │
└────────────────────────────────────────────────────────┘
```

---

## Requirements

* macOS 13.0 (Ventura) or later (Apple Silicon M1/M2/M3/M4 or Intel).
* Both your Mac and your Google Nest Mini must be connected to the same Wi-Fi network.

---

## Building from Source

NestCast uses the standard Swift Package Manager — no Xcode project configuration required.

### 1. Run Unit Tests
```bash
swift run NestCastTests
```

### 2. Build NestCast.app
```bash
bash build.sh
```
The compiled, codesigned application bundle will be created at `build/NestCast.app`.

To launch immediately:
```bash
open build/NestCast.app
```

### 3. Package DMG Installer
```bash
bash package.sh
```
Creates a verified `NestCast-1.0.0-arm64.dmg` and its `.sha256` checksum in the `dist/` directory.

---

## Project Structure

```
NestCast/
├── Package.swift                    # Swift Package Manager manifest
├── Info.plist                       # macOS bundle & permission metadata
├── build.sh                         # Standalone app bundle builder & codesigner
├── package.sh                       # DMG installer generator
├── Resources/
│   └── aircast                      # High-performance AirPlay bridge helper
├── Sources/
│   └── NestCast/
│       ├── NestCastApp.swift        # Main @main SwiftUI MenuBarExtra entrypoint
│       ├── Models/
│       │   └── CastDevice.swift     # Cast speaker model definition
│       ├── Discovery/
│       │   └── CastDiscovery.swift  # mDNS Bonjour discovery & TXT record parser
│       ├── Services/
│       │   ├── CastProtocol.swift   # Cast V2 TLS socket & Protobuf packet engine
│       │   ├── AudioStreamServer.swift # Local HTTP live audio streaming server
│       │   └── AirCastBridge.swift  # Embedded AirConnect daemon manager
│       └── Views/
│           ├── MenuBarView.swift    # Status bar dropdown popover view
│           ├── SpeakerRowView.swift # Individual speaker row & chime action
│           └── ActiveSessionView.swift # Now Casting card & volume slider
└── Tests/
    └── NestCastTests/
        └── main.swift               # Test runner verifying model & wire protocol
```

---

## License

MIT License. Authored by [gpsurya](https://github.com/gpsurya).
