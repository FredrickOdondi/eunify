# Continuity Bridge - System Interface Contract
**Version:** 1.0.0
**Status:** Active / Locked by Agent Gamma

## 1. Handshake & Discovery URI
The macOS host will encode the following schema into the GUI QR Code. The Android client will parse this string to establish the persistent socket:
```text
ws://<MAC_LOCAL_IP>:<PORT>/continuity?token=<SECURE_HANDSHAKE_HASH>
```

## 2. Browser Tab Drop Schema (ACTION_LAUNCH_URL)
When a browser tab or URL is dragged onto the macOS drop zone, the host transmits the following JSON payload. The Android client will parse this and trigger an `Intent.ACTION_VIEW` to launch the browser.

```json
{
  "type": "ACTION_LAUNCH_URL",
  "message_id": "uuid-v4-string",
  "timestamp": "ISO8601-timestamp",
  "payload": {
    "url": "https://target-url.com"
  }
}
```

## 3. Universal Clipboard Schema (ACTION_COPY_TEXT)
When highlighted text snippets or blocks of source code are dragged onto the macOS drop zone, the host transmits the following JSON payload. The Android client parses this, populates the mobile system clipboard buffers directly, and emits a success acknowledgment Toast notification.

```json
{
  "type": "ACTION_COPY_TEXT",
  "message_id": "uuid-v4-string",
  "timestamp": "ISO8601-timestamp",
  "payload": {
    "text": "const example = 'Hello from macOS host!';"
  }
}
```

## 4. WebRTC Signaling Orchestration Schemas
To establish secure, peer-to-peer binary file streaming over encrypted DataChannels, endpoints transmit session description payloads (SDP) and discovery nodes (ICE candidates) across the active Supabase cloud stream.

### A. Session Offer (ACTION_WEBRTC_OFFER)
```json
{
  "type": "ACTION_WEBRTC_OFFER",
  "sender_id": "macos_host",
  "payload": {
    "sdp": "v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1..."
  }
}
```

### B. Session Answer (ACTION_WEBRTC_ANSWER)
```json
{
  "type": "ACTION_WEBRTC_ANSWER",
  "sender_id": "android_client",
  "payload": {
    "sdp": "v=0\r\no=- 3562372488348234832 2 IN IP4 127.0.0.1..."
  }
}
```

### C. Network Discovery Node (ACTION_WEBRTC_ICE_CANDIDATE)
```json
{
  "type": "ACTION_WEBRTC_ICE_CANDIDATE",
  "sender_id": "macos_host",
  "payload": {
    "candidate": "candidate:842163049 1 udp 1677729535 192.168.1.50 58321 typ srflx...",
    "sdpMid": "0",
    "sdpMLineIndex": 0
  }
}
```

### D. File Transfer Initialization (ACTION_FILE_TRANSFER_START)
Transmitted over the established WebRTC DataChannel (or cloud socket) immediately preceding the sequence of binary chunk buffers.
```json
{
  "type": "ACTION_FILE_TRANSFER_START",
  "payload": {
    "file_name": "continuity_demo.mp4",
    "file_size": 15420312,
    "chunk_count": 236
  }
}
```

## 5. Notification Mirroring Schemas

To provide real-time notification presence on the desktop, the Android client intercepts incoming push notifications and broadcasts them to the host. If actionable, the host embeds interactive quick replies.

### A. Mirrored Notification Alert (ACTION_MIRROR_NOTIFICATION)
```json
{
  "type": "ACTION_MIRROR_NOTIFICATION",
  "message_id": "uuid-v4-string",
  "timestamp": "ISO8601-timestamp",
  "payload": {
    "notification_id": "unique-tag-or-id",
    "package_name": "com.whatsapp",
    "app_name": "WhatsApp",
    "title": "Alice",
    "body": "Hey, are we still meeting for lunch?",
    "can_reply": true
  }
}
```

### B. Reverse Quick Reply Action (ACTION_NOTIFICATION_REPLY)
Transmitted from the macOS host back to the Android client when a user submits a typed response inside the native desktop alert banner.
```json
{
  "type": "ACTION_NOTIFICATION_REPLY",
  "message_id": "uuid-v4-string",
  "timestamp": "ISO8601-timestamp",
  "payload": {
    "notification_id": "unique-tag-or-id",
    "reply_text": "Yes, see you in 10 mins!"
  }
}
```