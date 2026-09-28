# VR180 Camera (macOS)

A native macOS desktop client for VR180 3D stereoscopic cameras, fully compatible with the **Lenovo Mirage Camera with Daydream** and other cameras running the Google Daydream VR180 protocol.

---

## Key Features

- **Bluetooth Low Energy (BLE) Auto-Pairing & Reconnection**
  - Discovers nearby VR180 cameras over CoreBluetooth.
  - Implements ECDH P-256 key exchange, HKDF key derivation, AES-GCM encrypted control channel, and physical shutter button confirmation.
  - Pairing credentials persist in the macOS Keychain; subsequent launches automatically and silently reconnect without requiring camera re-pairing.

- **P2P WebRTC Stereoscopic Live Viewfinder**
  - Implements Google Daydream Camera's native WebRTC live preview protocol over local Wi-Fi.
  - Metal-accelerated hardware rendering (`RTCMTLNSVideoView`) for ultra-low latency real-time stereoscopic preview.
  - Automatic SDP negotiation, ICE candidate handling, and session keep-alives.

- **iOS-Inspired Camera Controls & UI**
  - **Immersive Viewfinder**: Dual-eye VR180 alignment reticles, tactile shutter animations, live flash feedback, pulsing recording indicator, and elapsed duration counter.
  - **Shooting Modes**: Fast switching between **Video**, **Photo**, and **Live Stream** modes.
  - **Live Badges**: Real-time battery indicator with charging state, remaining SD card storage, and Wi-Fi / BLE connectivity status.
  - **Remote Shutter**: Morphing recording button and responsive photo trigger.

- **Wi-Fi Hotspot & Media Management**
  - Remotely triggers the camera's built-in Wi-Fi Access Point, queries SSID & WPA2 password, and offers one-click automated connection via macOS network services.
  - Chunked protobuf media list pagination to prevent UI hangs on large SD cards.
  - High-speed HTTPS transfer with self-signed certificate authentication to preview thumbnails and download full-resolution 3D VR180 photos and videos directly to your `~/Downloads` folder.

---

## Project Structure

```text
VR180Camera/
├── Package.swift               # Swift Package manifest (Swift 6 & Swift 5 modes)
├── README.md                   # Project documentation and architecture guide
├── VALIDATION.md               # Hardware validation report (Lenovo Mirage Camera)
├── Scripts/
│   └── build_app.sh            # Release build & macOS .app bundle packaging script
├── Sources/
│   ├── VR180Protocol/          # Low-level protocol library
│   │   └── Protocol.swift      # Protobuf wire protocol, ECDH/HKDF/HMAC crypto & framing
│   └── VR180Camera/            # macOS SwiftUI application
│       ├── App.swift           # Main control panel and settings UI
│       ├── CameraManager.swift # Bluetooth, Wi-Fi, and media controller core
│       ├── CameraViewfinderSheet.swift # iOS-style viewfinder modal
│       ├── WebRtcViewfinderManager.swift # WebRTC P2P client & video renderer
│       └── PairingStore.swift  # Keychain persistence for pairing credentials
└── VR180Camera.app/            # Pre-built standalone macOS application bundle
```

---

## Building & Running

### Option 1: Run Pre-Built App Bundle
Double-click `VR180Camera.app` located in the project root directory.

### Option 2: Build App Bundle from Source
```bash
./Scripts/build_app.sh
```
The script will resolve dependencies (`WebRTC.xcframework`), compile in Release mode, embed required frameworks, configure `@executable_path`, and codesign the bundle.

### Option 3: Run via Swift Package Manager
```bash
swift run VR180Camera
```

---

## User Guide & Getting Started

1. **Initial Pairing**:
   - Power off the camera. Hold the physical Shutter/Photo button until the status LED alternates blue and green (Pairing Mode).
   - Launch `VR180Camera.app`. Discovered cameras will appear in the list.
   - Click **Connect**. When the status displays `Step 2/3: Press the camera shutter button!`, press the physical shutter button on the camera once to confirm.
   - The pairing key will be securely saved to your macOS Keychain for automatic future reconnection.

2. **Starting Real-Time Viewfinder**:
   - Click **Enable Camera Wi-Fi Hotspot** and connect your Mac to the camera's Wi-Fi network (or use the one-click **Connect Wi-Fi Automatically** button).
   - Click **Live Viewfinder Mode**. The window will automatically establish a WebRTC stereoscopic video stream with the camera.
