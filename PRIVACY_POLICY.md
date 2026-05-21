# Privacy Policy

**Effective Date:** May 21, 2026

## Overview
Eunify is an open-source Continuity Bridge designed to connect your Android device and macOS computer. We take your privacy seriously. Because Eunify is self-hosted and open-source, you are in full control of your data.

## Information Collection and Use
Eunify does **not** collect, store, or monetize any of your personal data. 

To function, the app requires certain device permissions. Here is exactly how they are used:

*   **Camera & Microphone:** Used exclusively for the Continuity Camera feature (streaming your phone's camera to your Mac) and scanning the initial pairing QR code. Video and audio streams are sent directly to your paired Mac via Peer-to-Peer WebRTC or the configured relay.
*   **Notifications:** Used solely to mirror your Android notifications to your Mac. Notification content is instantly encrypted and transmitted to your paired Mac. It is never stored on any server.
*   **Biometrics (Fingerprint/Face Unlock):** Used locally on your device to sign cryptographic challenges for unlocking your Mac. Your biometric data never leaves your device.
*   **Storage / Media:** Used to transfer files directly between your phone and Mac via Peer-to-Peer WebRTC. 

## Data Transmission (Cloud Relay & Peer-to-Peer)
*   **Supabase Realtime:** Eunify uses Supabase Realtime as a signaling server and message relay. Connection payloads (like URLs, clipboard text, or WebRTC signaling data) are broadcasted to the specific room you are paired with. 
*   **WebRTC DataChannels:** High-bandwidth data (like files and camera video streams) are transmitted directly from your phone to your Mac (Peer-to-Peer) whenever possible, bypassing the cloud relay entirely.

## Third-Party Services
The Eunify client uses Supabase for authentication (device pairing) and realtime WebSocket signaling. Please refer to [Supabase's Privacy Policy](https://supabase.com/privacy) for more details on how they handle infrastructure data.

## Open Source Transparency
Eunify is fully open-source. You can review the complete source code to verify our data handling practices at: [https://github.com/FredrickOdondi/eunify](https://github.com/FredrickOdondi/eunify)

## Contact
If you have any questions or concerns about this Privacy Policy, please open an issue on our GitHub repository.
