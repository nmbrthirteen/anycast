import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var controller: CastController
    @AppStorage("onboarded") private var onboarded = false
    @State private var step = 0
    private let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: WelcomeStep()
                case 1: FindTVStep()
                case 2: PermissionsStep()
                default: DoneStep()
                }
            }
            .id(step)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { index in
                        Capsule()
                            .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: index == step ? 18 : 6, height: 6)
                    }
                }
                Spacer()
                if step > 0 && step < steps - 1 {
                    Button("Back") { withAnimation { step -= 1 } }.buttonStyle(.glass)
                }
                Button(primaryTitle) {
                    if step == steps - 1 { onboarded = true } else { withAnimation { step += 1 } }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(24)
        }
        .frame(width: 520, height: 460)
    }

    private var primaryTitle: String {
        switch step {
        case 0: "Get started"
        case steps - 1: "Start casting"
        default: "Continue"
        }
    }
}

private struct StepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 76, height: 76)
                .glassEffect(.regular, in: .circle)
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Your TV, played from your Mac").font(.title.weight(.semibold))
            Text("Send web videos, files, and any window to your TV over Wi-Fi, at the best quality your TV can show.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }
}

private struct FindTVStep: View {
    @EnvironmentObject private var controller: CastController

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(symbol: "tv", title: "Find your TV",
                       subtitle: "If macOS asks to find devices on your network, click Allow.")
            HStack(spacing: 12) {
                if let tv = controller.renderer {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                    VStack(alignment: .leading) {
                        Text(tv.name).font(.headline)
                        Text("Ready to cast").font(.callout).foregroundStyle(.secondary)
                    }
                } else if controller.scanning {
                    ProgressView().controlSize(.small)
                    Text("Looking on your Wi-Fi")
                } else {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No TV found yet").font(.headline)
                        Text("Turn the TV on and join the same Wi-Fi. On Hisense TVs, turn on Anyview Stream.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Scan again", action: controller.scan).buttonStyle(.glass)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }
}

private struct PermissionsStep: View {
    @EnvironmentObject private var controller: CastController
    @State private var refresh = 0

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(symbol: "lock.shield", title: "Two quick permissions",
                       subtitle: "Both are optional. You can change them later in Settings.")
            VStack(spacing: 0) {
                row(title: "Screen recording", detail: "Mirror windows with sound",
                    allowed: Permissions.screenRecording == .allowed) {
                    Permissions.requestScreenRecording()
                }
                Divider().padding(.horizontal, 16)
                row(title: "Browser tabs", detail: "See your tabs and cast them in one click",
                    allowed: !controller.browsers.allSatisfy(\.tabs.isEmpty)) {
                    controller.refreshTabs()
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .id(refresh)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
    }

    private func row(title: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow", action: action).buttonStyle(.glass)
            }
        }
        .padding(16)
    }
}

private struct DoneStep: View {
    var body: some View {
        VStack(spacing: 22) {
            StepHeader(symbol: "checkmark", title: "You're all set", subtitle: "Three ways to cast:")
            VStack(alignment: .leading, spacing: 14) {
                tip("safari", "Double-click a browser tab in the sidebar to play its video on the TV.")
                tip("arrow.down.doc", "Drop a video, song, or photo anywhere in the window.")
                tip("rectangle.on.rectangle", "Use Mirror to send the window that's playing, with sound.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
        }
    }
}
