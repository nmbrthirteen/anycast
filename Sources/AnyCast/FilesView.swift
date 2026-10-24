import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject private var controller: CastController
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button { choosing = true } label: {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 34, weight: .medium)).foregroundStyle(.tint)
                    Text("Drop a video, song, or photo anywhere in this window").font(.headline)
                    Text("Or click to choose a file. Files your TV can play are sent untouched.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 170)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))

            if !controller.recentFiles.isEmpty {
                Text("Recent").font(.headline)
                List(controller.recentFiles, id: \.self) { url in
                    Button { controller.castFile(url) } label: {
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent).lineLimit(1)
                                Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                Spacer()
            }
        }
        .padding(24)
        .navigationTitle("Files")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.movie, .video, .audio, .image]) { result in
            if case .success(let url) = result { controller.castFile(url) }
        }
    }
}
