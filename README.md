# NestCast

<p align="center">
  <img src="https://raw.githubusercontent.com/gpsurya/NestCast/main/Resources/icon.png" width="128" height="128" alt="NestCast Logo" onerror="this.style.display='none'"/>
</p>

<p align="center">
  <strong>Native macOS Menu Bar app to stream desktop audio to Google Nest Mini & Chromecast speakers over Wi-Fi in Studio-Grade 320 kbps Hi-Fi.</strong>
</p>

<p align="center">
  <a href="https://github.com/gpsurya/NestCast/releases"><img src="https://img.shields.io/badge/Release-v1.0.3-blue.svg?style=flat-square" alt="Release v1.0.3"/></a>
  <a href="https://github.com/gpsurya/NestCast/releases"><img src="https://img.shields.io/badge/DMG-Verified%20Apple%20Silicon-green.svg?style=flat-square" alt="DMG Verified"/></a>
  <img src="https://img.shields.io/badge/macOS-13.0%2B%20(Ventura%2C%20Sonoma%2C%20Sequoia)-informational.svg?style=flat-square" alt="macOS 13+"/>
  <img src="https://img.shields.io/badge/Audio-320%20kbps%20CBR%20%E2%80%A2%2048%20kHz-orange.svg?style=flat-square" alt="Audio 320k 48kHz"/>
  <img src="https://img.shields.io/badge/Latency-Sub--second%20(%3C0.8s)-brightgreen.svg?style=flat-square" alt="Latency Sub-second"/>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-purple.svg?style=flat-square" alt="License MIT"/></a>
</p>

---

## Why NestCast?

macOS natively supports AirPlay, but completely excludes **Google Cast** devices (Google Nest Mini, Google Home, Google Nest Audio, Chromecast Audio). Users are traditionally forced into two subpar workarounds:

1. **Bluetooth Pairing:** Suffering from Bluetooth SBC/AAC compression artifacts, high latency, pairing dropout headaches, and strict 10-meter line-of-sight range limits.
2. **In-Browser Media Casting (Chrome/Brave):** Limited only to media played inside a specific browser tab; unable to stream system audio, native desktop apps, YouTube, JioSaavn, Spotify Desktop, Zoom, or terminal audio.

**NestCast solves this permanently.** It lives unobtrusively in your Mac menu bar, auto-discovers every Google Nest speaker on your Wi-Fi network, and streams your Mac's audio in **uncompressed 320 kbps Studio Quality @ 48,000 Hz** directly over Wi-Fi — with **sub-second instant connect and near-real-time synchronization**.

---

## Key Features

- **Studio-Grade 320 kbps CBR MP3 @ 48,000 Hz:** Direct CoreAudio DAC matching with zero resampling distortion or aliasing artifacts. Significantly superior to Bluetooth audio.
- **Sub-Second Instant Connect & Replay (<0.8s):** Pre-warmed streaming ingress eliminates cold-start process spin-up and edge DNS propagation delays. Connecting or replaying to a speaker takes just ~0.66 seconds.
- **Near-Real-Time Audio Pipeline (Low Latency):** Captured via SoX using a 1024-sample buffer (~21.3 ms frames at ~40 FPS) and served with `TCP_NODELAY` network socket dispatching. Keeps video dialogue and karaoke lyrics synchronized with speaker audio.
- **Instant Hardware Disconnect (<0.15s):** Dispatches Cast V2 `STOP` and `CLOSE` frames directly to the media receiver transport before socket closure. The speaker halts audio immediately without playing out leftover memory buffers, and Mac speakers resume playing in 1 ms.
- **Live Bi-Directional Volume Synchronization:** Interactive menu bar volume slider with intelligent anti-rubber-banding that prevents echo packet overwrites.
- **Dual-Mode Network Routing (Direct LAN + Zero-Trust Fallback):** Automatically streams over Direct Wi-Fi LAN; seamlessly activates outbound tunnel fallback for managed enterprise laptops subject to stealth-mode packet filters or corporate firewalls.
- **Zero Third-Party SDK Bloat:** Pure, native Swift implementation of the Google Cast V2 wire protocol (Protobuf framing over TLS on port `8009`).
- **AirPlay Bridge Mode:** Integrated one-click helper to expose all Google Nest speakers as native macOS AirPlay sound outputs.
- **Self-Contained Hardware Test Suite:** Built-in test runner that tests and verifies Cast V2 wire protocol, volume synchronization, and live physical speaker communication.

---

## Architecture & Audio Data Flow

```
┌────────────────────────────────────────────────────────────────────────┐
│                          macOS (NestCast Host)                         │
│                                                                        │
│   [Audio Source] (YouTube, JioSaavn, Spotify, System Audio, Zoom)      │
│          │ (Linear PCM CoreAudio Output)                               │
│          ▼                                                             │
│   [BlackHole 2ch Virtual Audio Driver] (48,000 Hz DAC)                 │
│          │                                                             │
│          ▼                                                             │
│   [DesktopAudioStreamer (SoX --buffer 1024)]                           │
│          │ (21.3 ms chunks • 320 kbps CBR MP3 @ 48 kHz)                │
│          ▼                                                             │
│   [AudioStreamServer (NWListener :8088)]                               │
│          │ (TCP_NODELAY • Real-time HTTP chunked live broadcast)       │
│          │                                                             │
│   [CastProtocol Engine]                                                │
│          │ (Cast V2 Wire Protobuf over TLS :8009)                      │
│          ├── Handshake: CONNECT -> receiver-0                          │
│          ├── App Launch: LAUNCH -> CC1AD845 (Default Media Receiver)   │
│          ├── Immediate Bind: CONNECT -> transportId                    │
│          └── Stream Command: LOAD -> /live.mp3                         │
└──────────┬─────────────────────────────────────────────────────────────┘
           │
           │ Direct Wi-Fi LAN / Zero-Trust Ingress Fallback
           ▼
┌────────────────────────────────────────────────────────────────────────┐
│                   Google Nest Mini / Chromecast Audio                  │
│                                                                        │
│   • Boots Google Cast Default Media Receiver (CC1AD845)                │
│   • Subscribes to Mac live HTTP broadcast stream                       │
│   • Hardware DAC decodes & plays Hi-Fi audio with zero Bluetooth jitter│
└────────────────────────────────────────────────────────────────────────┘
```

---

## Download & Installation

### Option 1: Drag-and-Drop DMG (Recommended)

1. Download the latest **`NestCast-1.0.3-arm64.dmg`** from the [GitHub Releases](https://github.com/gpsurya/NestCast/releases) page.
2. Double-click the DMG and drag **NestCast.app** into your **Applications** folder.
3. Install the two standard audio helpers via [Homebrew](https://brew.sh) (required for system audio routing and encoding):
   ```bash
   brew install blackhole-2ch sox
   ```
4. Launch **NestCast** from `/Applications`.
5. Look for the **NestCast** icon (`airplayaudio`) in your macOS Menu Bar at the top right of your screen.

> [!NOTE]
> macOS will request Microphone permission upon first audio stream start. This is macOS's standard TCC security prompt required whenever an application reads from an audio driver (BlackHole 2ch). NestCast never records your microphone.

---

## Quick Usage Guide

1. **Discover Speakers:** Open the NestCast menu bar popover. All Google Nest Minis, Google Homes, and Chromecast speakers on your local Wi-Fi will appear automatically.
2. **Start Casting:** Click the **Cast** button next to your speaker (e.g. *Surya speaker*).
   - NestCast redirects system audio to BlackHole.
   - Starts 320 kbps live streaming.
   - Connects to your speaker in **<0.8s**.
3. **Adjust Volume:** Use the responsive speaker volume slider directly inside the popover.
4. **Instant Disconnect:** Click **Disconnect**. NestCast cuts speaker audio immediately (<0.15s) and restores your Mac's built-in speakers.

---

## Building from Source

NestCast is written in pure Swift 5.9+ using Swift Package Manager.

### Prerequisites
- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools (`xcode-select --install`)
- `blackhole-2ch` and `sox` installed (`brew install blackhole-2ch sox`)

### 1. Clone Repository
```bash
git clone https://github.com/gpsurya/NestCast.git
cd NestCast
```

### 2. Run Comprehensive Hardware & Protocol Tests
```bash
swift run NestCastTests
```
*Executes all 10 unit and hardware verification suites against live network devices.*

### 3. Build Standalone Application Bundle
```bash
bash build.sh
```
*Compiles the release binary, bundles resources, and code-signs `build/NestCast.app`.*

### 4. Generate Verified DMG Installer
```bash
bash package.sh
```
*Builds a verified drag-to-Applications DMG at `dist/NestCast-1.0.3-arm64.dmg` with SHA-256 checksum.*

---

## Project Structure

```
NestCast/
├── Package.swift                       # SPM package manifest
├── Info.plist                          # Bundle identifier & permission descriptions
├── build.sh                            # Automated build & code-signing script
├── package.sh                          # DMG disk image creation script
├── Resources/
│   ├── aircast                         # High-performance AirPlay bridge helper
│   └── chime.ogg                       # Local fallback chime sample
├── Sources/
│   └── NestCast/
│       ├── main.swift                  # Application entrypoint & NSApplicationDelegate
│       ├── StatusBarController.swift   # Menu Bar status item & NSPopover manager
│       ├── Models/
│       │   └── CastDevice.swift        # Speaker data models & volume properties
│       ├── Discovery/
│       │   └── CastDiscovery.swift     # Bonjour mDNS & Eureka REST discovery
│       ├── Services/
│       │   ├── AudioDeviceManager.swift    # CoreAudio HAL default output switching
│       │   ├── DesktopAudioStreamer.swift  # SoX capture & background ingress engine
│       │   ├── AudioStreamServer.swift     # Real-time HTTP streaming server (TCP_NODELAY)
│       │   ├── CastProtocol.swift          # Cast V2 Protobuf TLS engine & event dispatcher
│       │   ├── AirCastBridge.swift         # AirConnect AirPlay compatibility service
│       │   └── LogManager.swift            # Rotating file logger (~/Library/Logs/NestCast.log)
│       └── Views/
│           ├── MenuBarView.swift       # Dropdown UI popover
│           ├── SpeakerRowView.swift    # Individual speaker row & status
│           └── ActiveSessionView.swift # Now Casting card, live stats & volume slider
├── Tests/
│   └── NestCastTests/
│       └── main.swift                  # 10-point test runner & wire protocol verifier
└── dist/
    ├── NestCast-1.0.3-arm64.dmg        # Compiled release installer disk image
    └── NestCast-1.0.3-arm64.dmg.sha256 # Cryptographic checksum
```

---

## Compatibility

| Device | Tested & Supported |
| :--- | :---: |
| Google Nest Mini (2nd Generation) | ✅ Verified |
| Google Home Mini (1st Generation) | ✅ Verified |
| Google Nest Audio | ✅ Verified |
| Google Home (Original) | ✅ Verified |
| Chromecast Audio | ✅ Verified |
| Google Nest Hub / Hub Max | ✅ Verified |

---

## Author & Acknowledgements

- **Author:** [@gpsurya](https://github.com/gpsurya)
- **Protocol Reference:** Google Cast V2 Wire Protocol reverse-engineering specifications and [AirConnect](https://github.com/philippe44/AirConnect) project.

---

## License

This project is licensed under the [MIT License](LICENSE).
