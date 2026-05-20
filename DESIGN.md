# Visual Interface & State Binding Contract
**Status:** Active / Maintained by Alpha and Beta

## 1. macOS Host ViewModels (Consumed by Agent Delta)
Agent Alpha exposes the following `@Observable` state properties for the UI layer to bind to:
- `AppState.isServerActive` (Bool) -> Drives the frosted glass border glow.
- `AppState.localIPAddress` (String) -> Fed into the QR code vector generator.
- `AppState.lastDroppedURL` (String?) -> Renders the success HUD pop-up.

## 2. Android Client StateFlow (Consumed by Agent Epsilon)
Agent Beta exposes the following unilinear UI states from the Repository layer:
- `SocketState.Connecting` -> Trigger dynamic Material Design 3 loading spinners.
- `SocketState.Connected(hostIp)` -> Collapse the CameraX layout, render the persistent dashboard.
- `SocketState.Error(message)` -> Surface a native snackbar with a "Reconnect" trigger.