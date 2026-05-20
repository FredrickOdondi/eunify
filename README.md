# eunify

> **Continuity Bridge for Android & Mac** — drag tabs, sync clipboards, mirror notifications, stream your phone camera, and unlock your Mac with your fingerprint. All over the cloud.

![Platform](https://img.shields.io/badge/macOS-13%2B-black?style=flat-square&logo=apple)
![Platform](https://img.shields.io/badge/Android-8%2B-3DDC84?style=flat-square&logo=android)
![Built with](https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&logo=swift)
![Built with](https://img.shields.io/badge/Flutter-Dart-02569B?style=flat-square&logo=flutter)
![Backend](https://img.shields.io/badge/Supabase-Realtime-3ECF8E?style=flat-square&logo=supabase)
![Release](https://img.shields.io/github/v/release/FredrickOdondi/eunify?style=flat-square&color=brightgreen)

## ⬇️ Download

| Platform | Link |
|---|---|
| 🍎 **macOS** (13+) | [Download v1.0.0](https://github.com/FredrickOdondi/eunify/releases/tag/v1.0.0) |
| 🤖 **Android** | Sideload APK — see [Releases](https://github.com/FredrickOdondi/eunify/releases) |

> **macOS:** Unzip → drag `eunify.app` to Applications → Right-click → **Open** on first launch (Gatekeeper bypass)

---

## What is Eunify?

Apple users get Handoff, AirDrop, Universal Clipboard, and Continuity Camera out of the box. Android users get nothing.

**Eunify fixes that.**

It's a native macOS app + Android client that bridges your two devices over a cloud relay — giving Android users the same seamless, real-time continuity features that were previously exclusive to the Apple ecosystem.

---

## Features

| Feature | Description |
|---|---|
| 🌐 **Tab & URL Push** | Drag a Chrome or Safari tab onto the Mac app — it opens instantly on your phone |
| 📋 **Universal Clipboard** | Copy text or code on your Mac and it lands in your Android clipboard |
| 🔗 **Reverse URL Push** | Send a link from your Android back to your Mac browser |
| 🔔 **Notification Mirroring** | Android notifications appear on your Mac in real time, with quick-reply support |
| 📁 **File Transfer** | Drag any file onto the Mac app and send it directly to your Android via P2P WebRTC |
| 📷 **Continuity Camera** | Use your Android phone as a wireless webcam for your Mac |
| 🔒 **Biometric Mac Unlock** | Tap your fingerprint on your phone to unlock your Mac remotely |
| 🎵 **Media Sync** | See what's playing on your Android and control it from your Mac |

---

## How It Works

```
macOS App ──── Supabase Realtime (WebSocket) ────  Android Client
                         │
                    (signaling)
                         │
macOS App ◄─────── WebRTC P2P ──────────────────► Android Client
                  (files & camera)
```

1. The macOS app generates a **QR code** encoding a unique room ID
2. The Android app **scans the QR code** to join the same Supabase Realtime channel
3. Both devices exchange structured JSON payloads over the cloud relay
4. For binary data (files, camera frames), a **WebRTC DataChannel** is negotiated for direct peer-to-peer streaming

---

## Project Structure

```
eunify/
├── eunify/                  # macOS Host App (Swift + SwiftUI)
│   ├── eunifyApp.swift      # App entry, NetworkServer, AppState, UnlockService
│   ├── ContentView.swift    # Full UI with 6 feature tabs
│   ├── MediaView.swift      # Now Playing widget
│   └── WebRTCManager.swift  # WebRTC peer connection manager
│
├── Android-Client/          # Android Client (Flutter)
│   ├── lib/
│   │   ├── main.dart        # App entry + routing
│   │   ├── screens/         # Splash, Auth, Scanner, Dashboard
│   │   └── services/        # Relay, Camera, Notifications, Biometric, WebRTC
│   └── android/             # Native Android config & Kotlin files
│
├── shared/networking/       # Shared networking schemas (Swift)
│   ├── PayloadSchema.swift
│   ├── WebSocketServer.swift
│   └── NetworkDiscovery.swift
│
├── PROTOCOL.md              # Full message payload schema reference
├── DESIGN.md                # UI state binding contracts
└── SHIPPING.md              # Git commit conventions
```

---

## Getting Started

### Prerequisites

- **Mac:** macOS 13+, Xcode 15+
- **Android:** Android 8.0+ (API 26+), Flutter 3.3+
- A free [Supabase](https://supabase.com) project with Realtime enabled

### macOS App

1. Clone the repo and open `eunify.xcodeproj` in Xcode
2. Set your development team in **Signing & Capabilities**
3. Build & run on your Mac (`⌘R`)

### Android Client

```bash
cd Android-Client
flutter pub get
flutter run
```

### Supabase Setup

The app uses Supabase Realtime for the cloud relay. Update the credentials in:
- `eunify/eunifyApp.swift` → `supabaseUrl` constant
- `Android-Client/lib/config/supabase_config.dart` → `SupabaseConfig`

---

## Protocol

All messages follow a structured JSON schema. See [`PROTOCOL.md`](PROTOCOL.md) for the full reference.

Key events:

| Event | Direction | Purpose |
|---|---|---|
| `ACTION_LAUNCH_URL` | Mac → Android | Open URL on phone |
| `ACTION_COPY_TEXT` | Mac → Android | Copy text to phone clipboard |
| `HOST_LAUNCH_URL` | Android → Mac | Send URL to Mac browser |
| `ACTION_MIRROR_NOTIFICATION` | Android → Mac | Mirror push notification |
| `ACTION_NOTIFICATION_REPLY` | Mac → Android | Send quick reply |
| `ACTION_WEBRTC_OFFER/ANSWER` | Both | WebRTC signaling |
| `CLIENT_UNLOCK_CHALLENGE` | Mac → Android | Trigger biometric unlock |

---

## Background Sync on Android

Android background reliability is handled with a **two-layer approach**:

1. **Foreground Service** — A persistent notification keeps the Supabase WebSocket connection alive with a WakeLock, even when the app is in the background
2. **Background Isolate** — A separate Dart isolate re-initializes Supabase independently and handles delivery if the main UI is killed by the OS. Received payloads are queued to `SharedPreferences` and the app is trampolined to the foreground to execute them

> **Note on Android 10+ clipboard restrictions:** Android 10+ blocks background apps from writing to the clipboard. Eunify works around this by using `FlutterForegroundTask.launchApp()` to bring the app to the foreground before writing clipboard data.

---

## Distribution

The Android APK is available as a direct download from [GitHub Releases](https://github.com/FredrickOdondi/eunify/releases). No Play Store required — just download, enable "Install from unknown sources", and sideload.

---

## License

MIT — free to use, fork, and build on.
