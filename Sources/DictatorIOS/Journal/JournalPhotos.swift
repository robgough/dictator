import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Photos in the iPhone journal. Stored exactly as the Mac stores them (see
// `JournalAttachments`): a file in `attachments/` beside the day's note and
// an ordinary Markdown image link under the entry's words.

// MARK: - Showing photos

/// A group of photos in an entry. One is drawn at its own shape; several
/// become a grid of square tiles, as on the Mac, so a moment with four
/// photos isn't four screens of scrolling.
struct JournalPhotoGrid: View {
    let images: [JournalMarkdown.ResolvedImage]
    var onOpen: (URL) -> Void

    private let gap: CGFloat = 4

    var body: some View {
        if images.count == 1 {
            JournalPhotoView(image: images[0], maxPixel: 1200, fill: false)
                .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { if let url = images[0].url { onOpen(url) } }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap),
                                     count: images.count == 2 || images.count == 4 ? 2 : 3),
                      spacing: gap) {
                ForEach(images) { image in
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { JournalPhotoView(image: image, maxPixel: 600, fill: true) }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { if let url = image.url { onOpen(url) } }
                }
            }
        }
    }
}

/// One photo, decoded off the main thread at the size it's drawn at.
struct JournalPhotoView: View {
    let image: JournalMarkdown.ResolvedImage
    let maxPixel: Int
    let fill: Bool

    @State private var loaded: UIImage?

    var body: some View {
        Group {
            if image.url == nil {
                // Moved or deleted — say so rather than leaving a hole.
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("Photo not found").font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(Color(.secondarySystemBackground))
            } else if let loaded {
                Image(uiImage: loaded)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Color(.secondarySystemBackground)
                    .frame(minHeight: 80)
            }
        }
        .task(id: image.url) {
            guard let url = image.url else { return }
            let size = maxPixel * Int(UITraitCollection.current.displayScale)
            loaded = await Task.detached { JournalPhotoLoader.thumbnail(url, maxPixel: size) }.value
        }
    }
}

enum JournalPhotoLoader {
    /// A downsampled decode — a 48-megapixel photo drawn in a 300-point
    /// tile shouldn't cost 190 MB of memory.
    nonisolated static func thumbnail(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Full screen. Pinch or double-tap to zoom, drag to pan when zoomed, and
/// drag down with one finger to close — the photo follows the finger and
/// the black fades, as in Photos.
struct JournalPhotoViewer: View {
    let url: URL
    /// Closes the viewer. Explicit rather than the environment's `dismiss`,
    /// which didn't reliably reach the full-screen cover from here.
    let onClose: () -> Void
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    /// Where a zoomed photo has been panned to.
    @State private var pan: CGSize = .zero
    @State private var settledPan: CGSize = .zero
    /// How far an unzoomed photo has been dragged towards closing.
    @State private var pull: CGSize = .zero

    /// Past this, letting go closes the viewer.
    private let closeDistance: CGFloat = 120

    private var isZoomed: Bool { scale > 1.01 }

    /// 1 at rest, fading as the photo is pulled away.
    private var backdropOpacity: Double {
        1 - min(Double(abs(pull.height) / 400), 0.75)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale * (1 - min(abs(pull.height) / 2000, 0.15)))
                    .offset(x: pan.width + pull.width, y: pan.height + pull.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(drag)
                    .simultaneousGesture(magnify)
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            if isZoomed {
                                scale = 1
                                pan = .zero
                            } else {
                                scale = 2.5
                            }
                        }
                        settledScale = scale
                        settledPan = pan
                    }
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // On top of everything, outside the photo's gestures, so a tap on it
        // can never be taken for the start of a drag or a double-tap.
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .padding()
            .opacity(pull == .zero ? 1 : 0)
            .accessibilityLabel("Close")
        }
        // The cover's own background would show behind the fading black.
        .presentationBackground(.clear)
        .task {
            image = await Task.detached { JournalPhotoLoader.thumbnail(url, maxPixel: 4096) }.value
        }
    }

    /// One finger: pans a zoomed photo, otherwise pulls it towards closing.
    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if isZoomed {
                    pan = CGSize(width: settledPan.width + value.translation.width,
                                 height: settledPan.height + value.translation.height)
                } else {
                    pull = value.translation
                }
            }
            .onEnded { value in
                if isZoomed {
                    settledPan = pan
                    return
                }
                let flung = value.predictedEndTranslation.height
                if abs(value.translation.height) > closeDistance || abs(flung) > closeDistance * 3 {
                    // Carry on in the direction of the throw, then go.
                    withAnimation(.easeOut(duration: 0.18)) {
                        pull.height = value.translation.height < 0 ? -1200 : 1200
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(170))
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { onClose() }
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pull = .zero }
                }
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { scale = max(1, settledScale * $0.magnification) }
            .onEnded { _ in
                settledScale = scale
                if !isZoomed {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pan = .zero }
                    settledPan = .zero
                }
            }
    }
}

// MARK: - Getting photos in

enum JournalPhotoImport {
    /// The long edge photos are kept at. Big enough to look sharp full
    /// screen on any phone, small enough that a journal synced over iCloud
    /// doesn't grow by 10 MB a picture.
    static let maxLongEdge: CGFloat = 3024

    /// Camera captures and library HEICs become JPEG. HEIC is what the
    /// iPhone shoots, but most Markdown apps that will open this journal
    /// (Obsidian among them) can't show it. PNG and GIF are kept as they
    /// are — re-encoding a screenshot or an animation would only lose.
    static func photo(from image: UIImage) -> JournalModel.PendingPhoto? {
        let scaled = downscaled(image)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { return nil }
        return JournalModel.PendingPhoto(data: data, fileExtension: "jpg", name: "photo")
    }

    static func photo(from item: PhotosPickerItem) async -> JournalModel.PendingPhoto? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
        if let type, type.conforms(to: .png) || type.conforms(to: .gif),
           let ext = type.preferredFilenameExtension {
            return JournalModel.PendingPhoto(data: data, fileExtension: ext, name: "photo")
        }
        guard let image = UIImage(data: data) else { return nil }
        return photo(from: image)
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let longEdge = max(image.size.width, image.size.height) * image.scale
        guard longEdge > maxLongEdge else { return image }
        let factor = maxLongEdge / longEdge
        let size = CGSize(width: image.size.width * image.scale * factor,
                          height: image.size.height * image.scale * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// The system camera. SwiftUI has no camera view of its own.
struct JournalCamera: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: JournalCamera
        init(_ parent: JournalCamera) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
