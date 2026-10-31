import SwiftUI

struct NowPlayingBar: View {
    @EnvironmentObject private var controller: CastController
    @State private var scrub: Double?

    var body: some View {
        if let plan = controller.plan {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 16) {
                    Image(systemName: icon(for: plan))
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: .rect(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(plan.title).font(.headline).lineLimit(1)
                            Text(plan.mode.label)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .glassEffect(.regular.tint(.accentColor.opacity(0.3)), in: .capsule)
                                .help(plan.mode.rawValue)
                        }
                        if controller.canSeek {
                            HStack(spacing: 8) {
                                Text(DLNAClient.format(scrub ?? controller.currentTime))
                                Slider(value: Binding(get: { scrub ?? controller.currentTime }, set: { scrub = $0 }),
                                       in: 0...max(controller.duration, 1)) { editing in
                                    if !editing, let scrub {
                                        controller.seek(to: scrub)
                                        self.scrub = nil
                                    }
                                }
                                .controlSize(.small)
                                Text(DLNAClient.format(controller.duration))
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        } else {
                            Text(plan.mode.rawValue).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }

                    HStack(spacing: 8) {
                        if controller.canPause {
                            Button(action: controller.togglePause) {
                                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").frame(width: 22, height: 22)
                            }
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.circle)
                            .controlSize(.large)
                            .keyboardShortcut(.space, modifiers: [])
                        }

                        Button(action: controller.stop) { Image(systemName: "stop.fill").frame(width: 22, height: 22) }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .controlSize(.large)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { controller.volume }, set: controller.setVolume), in: 0...100)
                            .controlSize(.small)
                            .frame(width: 110)
                    }

                    if plan.fallback != nil {
                        Button("Retry via Mac", systemImage: "arrow.triangle.2.circlepath", action: controller.useFallback)
                            .buttonStyle(.glass)
                            .help("Use this if the TV doesn't start playing")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .rect(cornerRadius: 26))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func icon(for plan: CastPlan) -> String {
        switch (plan.mode, plan.kind) {
        case (.mirror, _): "rectangle.on.rectangle"
        case (.tab, _): "safari"
        case (_, .audio): "music.note"
        case (_, .image): "photo"
        default: "play.tv.fill"
        }
    }
}

struct StatusBanner: View {
    @EnvironmentObject private var controller: CastController

    var body: some View {
        if let working = controller.working {
            Label {
                Text(working)
            } icon: {
                ProgressView().controlSize(.small)
            }
            .banner()
        } else if let message = controller.message {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(3)
                Button { controller.message = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .banner()
        }
    }
}

private extension View {
    func banner() -> some View {
        font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 560)
            .padding(.top, 8)
            .padding(.horizontal, 16)
    }
}
