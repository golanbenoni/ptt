import SwiftUI
import PttTalkLib
import ImageIO
import UniformTypeIdentifiers
import AVKit

enum ChatPhotoNormalizer {
    static func jpeg(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        // A new image destination gets pixel data only, not source EXIF/GPS metadata.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}

enum ChatVideoPreview {
    static func image(_ data: Data) -> UIImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ptt-video-preview-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            return try UIImage(cgImage: generator.copyCGImage(at: .zero, actualTime: nil))
        } catch { return nil }
    }
}

struct StagedMediaSheet: View {
    @ObservedObject var model: TalkModel
    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Review before sending. Up to 10 items, 25 MiB each. Each caption may use up to 4096 UTF-8 bytes.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(model.chatStatus).font(.footnote).accessibilityIdentifier("Media status")
                }
                ForEach(model.stagedChatAttachments) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        StagedMediaThumbnail(model: model, item: item)
                        Text(item.fileName).font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file)).font(.caption)
                        TextField("Caption", text: Binding(get: {
                            model.stagedChatAttachments.first(where: { $0.id == item.id })?.caption ?? ""
                        }, set: { model.updateStagedCaption($0, id: item.id) }), axis: .vertical).lineLimit(1...5)
                        HStack {
                            Button("Move earlier") { Task { await model.moveStagedAttachment(item.id, offset: -1) } }
                                .disabled(model.stagedChatAttachments.first?.id == item.id)
                            Button("Move later") { Task { await model.moveStagedAttachment(item.id, offset: 1) } }
                                .disabled(model.stagedChatAttachments.last?.id == item.id)
                            Spacer()
                            Button("Remove", role: .destructive) { Task { await model.removeStagedAttachment(item.id) } }
                        }.font(.caption).buttonStyle(.borderless)
                    }.padding(.vertical, 6)
                }
            }.disabled(sending)
            .navigationTitle("Review attachments")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep draft") { dismiss() }.disabled(sending) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Saving…" : "Send \(model.stagedChatAttachments.count)") {
                        sending = true
                        Task { await model.sendStagedAttachments(); sending = false; if model.stagedChatAttachments.isEmpty { dismiss() } }
                    }.disabled(sending || model.stagedChatAttachments.isEmpty || model.stagedChatAttachments.contains { $0.caption.utf8.count > 4096 })
                }
            }.interactiveDismissDisabled(sending)
        }
    }
}

private struct StagedMediaThumbnail: View {
    let model: TalkModel
    let item: ChatStagedAttachment
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220) }
            else { Label(item.mimeType.hasPrefix("video/") ? "Video" : "Attachment", systemImage: item.mimeType.hasPrefix("video/") ? "video" : "doc") }
        }.task(id: item.id) {
            if let data = await model.stagedData(item.id) {
                if item.mimeType.hasPrefix("image/") { image = UIImage(data: data) }
                else if item.mimeType.hasPrefix("video/") { image = ChatVideoPreview.image(data) }
            }
        }
    }
}

struct ChatCameraPicker: UIViewControllerRepresentable {
    var finished: (Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finished: (Data?) -> Void
        init(finished: @escaping (Data?) -> Void) { self.finished = finished }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finished(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            finished((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.95))
        }
    }
}

private struct ExportedChatFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ChatMediaViewer: View {
    let url: URL
    let mime: String
    let caption: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var export: ExportedChatFile?
    @State private var exporting = false
    @State private var status = ""
    var body: some View {
        NavigationStack {
            VStack {
                if mime.hasPrefix("video/") {
                    VideoPlayer(player: player).onAppear { player = AVPlayer(url: url) }.onDisappear { player?.pause(); player = nil }
                } else if let image {
                    ScrollView([.horizontal, .vertical]) { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 800) }
                } else if !status.isEmpty {
                    VStack(spacing: 12) {
                        Label("Preview unavailable", systemImage: "photo").font(.headline)
                        Text("This file could not be decoded. You can still save or share the original.")
                    }.padding()
                } else { ProgressView("Loading photo…") }
                if !caption.isEmpty { ScrollView { Text(caption).padding() }.frame(maxHeight: 150) }
                if !status.isEmpty { Text(status).font(.caption).padding(8) }
            }
            .navigationTitle("Media")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Save") {
                        do { export = ExportedChatFile(data: try Data(contentsOf: url)); exporting = true }
                        catch { status = "Could not prepare this file. Reopen the attachment and retry." }
                    }
                    ShareLink("Share", item: url)
                }
            }
            .fileExporter(isPresented: $exporting, document: export, contentType: UTType(mimeType: mime) ?? .data, defaultFilename: url.lastPathComponent) { result in
                if case .failure = result { status = "File was not saved. You can retry." }
            }
            .task {
                if mime.hasPrefix("image/"), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) { image = UIImage(cgImage: cgImage) }
                else if mime.hasPrefix("image/") { status = "Photo preview could not be loaded." }
            }
        }
    }
}
