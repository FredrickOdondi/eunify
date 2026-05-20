import SwiftUI

struct MediaView: View {
    @ObservedObject var appState = AppState.shared
    
    var body: some View {
        VStack(spacing: 24) {
            if let metadata = appState.nowPlaying {
                // Background blurred art
                ZStack {
                    if let base64 = metadata.albumArtBase64,
                       let data = Data(base64Encoded: base64.replacingOccurrences(of: "data:image/jpeg;base64,", with: "")),
                       let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 300, height: 300)
                            .blur(radius: 40)
                            .opacity(0.4)
                    }
                    
                    VStack(spacing: 20) {
                        // Main Art
                        if let base64 = metadata.albumArtBase64,
                           let data = Data(base64Encoded: base64.replacingOccurrences(of: "data:image/jpeg;base64,", with: "")),
                           let nsImage = NSImage(data: data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 220, height: 220)
                                .cornerRadius(20)
                                .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
                        } else {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(Color.secondary.opacity(0.2))
                                .frame(width: 220, height: 220)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.system(size: 80))
                                        .foregroundColor(.secondary)
                                )
                        }
                        
                        VStack(spacing: 8) {
                            Text(metadata.title)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .multilineTextAlignment(.center)
                            
                            Text(metadata.artist)
                                .font(.system(size: 18, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 6) {
                                Image(systemName: "iphone")
                                    .font(.caption)
                                Text(metadata.appName)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .textCase(.uppercase)
                            }
                            .foregroundColor(.purple)
                            .padding(.top, 4)
                        }
                        .padding(.horizontal)
                        
                        // Controls
                        HStack(spacing: 40) {
                            Button(action: { NetworkServer.shared.sendMediaControl("SKIP_BACKWARD") }) {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 28))
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            Button(action: { NetworkServer.shared.sendMediaControl("PAUSE") }) {
                                ZStack {
                                    Circle()
                                        .fill(Color.primary)
                                        .frame(width: 64, height: 64)
                                    
                                    Image(systemName: "pause.fill")
                                        .font(.system(size: 32))
                                        .foregroundColor(Color(NSColor.windowBackgroundColor))
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            Button(action: { NetworkServer.shared.sendMediaControl("SKIP_FORWARD") }) {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 28))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
                .cornerRadius(32)
                .padding(20)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary.opacity(0.5))
                    
                    Text("No Media Playing")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text("Open Spotify or YouTube on your paired Android device to control it from here.")
                        .font(.subheadline)
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
