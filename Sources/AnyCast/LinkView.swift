import SwiftUI

struct LinkView: View {
    @EnvironmentObject private var controller: CastController
    @State private var link = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "link")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 84, height: 84)
                .glassEffect(.regular, in: .circle)
            VStack(spacing: 6) {
                Text("Play a video link on your TV").font(.title2.weight(.semibold))
                Text("Works with YouTube, Vimeo, X, Twitch, and most video sites. AnyCast picks the best quality your TV can play.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            GlassEffectContainer {
                HStack(spacing: 10) {
                    TextField("https://", text: $link)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .glassEffect(.regular, in: .capsule)
                        .onSubmit { controller.castLink(link) }
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        link = NSPasteboard.general.string(forType: .string) ?? link
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    Button("Cast", systemImage: "play.tv.fill") { controller.castLink(link) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(link.isEmpty)
                }
            }
            .frame(maxWidth: 560)
        }
        .padding(40)
        .navigationTitle("Video link")
        .onAppear {
            if link.isEmpty, let clip = NSPasteboard.general.string(forType: .string), clip.hasPrefix("http") { link = clip }
        }
    }
}
