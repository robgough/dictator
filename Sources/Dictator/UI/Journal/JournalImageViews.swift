import AppKit
import SwiftUI

/// Photos in an entry.
///
/// Two rules, both learned by looking at it:
///
/// * **A group is laid out, not stacked.** Several photos from one moment are
///   one thing that happened. Down the page at full width they turn a morning
///   into a scroll, so two or more become a grid — a big one with smaller ones
///   beside it, the shape a photo grid has everywhere else.
/// * **Nothing is ever enlarged.** A single photo is drawn at its own size,
///   capped to the column. Before this, `resizable()` plus a full-width frame
///   scaled a 300-pixel screenshot up to 620 points and it looked like a
///   mistake, because it was one.
struct JournalImageGrid: View {
    let images: [JournalMarkdown.ResolvedImage]
    /// The text column's width, which is the widest a photo may be.
    var measure: CGFloat = 620

    private let gap: CGFloat = 6

    var body: some View {
        switch images.count {
        case 0:
            EmptyView()
        case 1:
            JournalSinglePhoto(image: images[0], measure: measure)
        case 2:
            HStack(spacing: gap) {
                tile(images[0], height: 190)
                tile(images[1], height: 190)
            }
        case 3:
            // One big, two stacked beside it. The first photo of a group is
            // usually the one that was worth taking.
            HStack(spacing: gap) {
                tile(images[0], height: 260)
                    .frame(maxWidth: .infinity)
                VStack(spacing: gap) {
                    tile(images[1], height: 127)
                    tile(images[2], height: 127)
                }
                .frame(width: 150)
            }
        case 4:
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    tile(images[0], height: 150)
                    tile(images[1], height: 150)
                }
                HStack(spacing: gap) {
                    tile(images[2], height: 150)
                    tile(images[3], height: 150)
                }
            }
        default:
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: 3),
                spacing: gap
            ) {
                ForEach(images) { image in
                    tile(image, height: 120)
                }
            }
        }
    }

    private func tile(_ image: JournalMarkdown.ResolvedImage, height: CGFloat) -> some View {
        JournalPhotoTile(image: image, height: height)
    }
}

/// One photo on its own, at its own size.
struct JournalSinglePhoto: View {
    let image: JournalMarkdown.ResolvedImage
    var measure: CGFloat = 620

    @State private var loaded: LoadedPhoto?

    var body: some View {
        Group {
            if image.url == nil {
                JournalMissingPhoto(reference: image.ref.reference)
            } else if let loaded {
                Image(nsImage: loaded.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // Capped by the column *and* by the photo's own size, so a
                    // small one stays small.
                    .frame(maxWidth: min(loaded.naturalWidth, measure),
                           maxHeight: min(loaded.naturalHeight, 420),
                           alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.quaternary))
                    .photoActions(url: image.url)
            } else {
                JournalPhotoPlaceholder(height: 200)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: image.url) { loaded = await JournalPhotoLoader.load(image.url) }
    }
}

/// A photo in a grid: fills its tile and is cropped to it, which is what makes
/// a row of them line up.
struct JournalPhotoTile: View {
    let image: JournalMarkdown.ResolvedImage
    let height: CGFloat

    @State private var loaded: LoadedPhoto?

    var body: some View {
        Group {
            if image.url == nil {
                JournalMissingPhoto(reference: image.ref.reference, compact: true)
                    .frame(height: height)
            } else if let loaded {
                Color.clear
                    .overlay {
                        Image(nsImage: loaded.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.quaternary))
                    .photoActions(url: image.url)
            } else {
                JournalPhotoPlaceholder(height: height)
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: image.url) { loaded = await JournalPhotoLoader.load(image.url) }
    }
}

private struct JournalPhotoPlaceholder: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.quaternary.opacity(0.3))
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }
}

/// Says which file has gone rather than leaving a gap. A photo that has moved
/// is something the user can fix; a silently missing one isn't.
struct JournalMissingPhoto: View {
    let reference: String
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.orange)
            if !compact {
                Text("Missing image: \(reference)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.quaternary))
        .help(compact ? "Missing image: \(reference)" : "")
    }
}

/// A decoded photo and the size it wants to be drawn at.
struct LoadedPhoto: Equatable {
    let image: NSImage
    let naturalWidth: CGFloat
    let naturalHeight: CGFloat
}

enum JournalPhotoLoader {
    /// Decoded off the main actor and downsampled on the way in — a page of
    /// full-resolution photographs would otherwise be decoded at full size for
    /// a 620-point column.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` only ever shrinks, so a photo
    /// smaller than the cap comes back at its own resolution, which is what
    /// lets the views refuse to enlarge it.
    static func load(_ url: URL?) async -> LoadedPhoto? {
        guard let url else { return nil }
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        return await Task.detached(priority: .userInitiated) { () -> LoadedPhoto? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            let pixelSize = NSSize(width: cgImage.width, height: cgImage.height)
            return LoadedPhoto(
                image: NSImage(cgImage: cgImage, size: pixelSize),
                naturalWidth: pixelSize.width / scale,
                naturalHeight: pixelSize.height / scale)
        }.value
    }
}

private extension View {
    /// Click to open, right-click for the rest. Preview is the right place to
    /// look at a photograph properly; this window's job is the page.
    func photoActions(url: URL?) -> some View {
        self
            .onTapGesture { if let url { NSWorkspace.shared.open(url) } }
            .contextMenu {
                if let url {
                    Button("Open in Preview") { NSWorkspace.shared.open(url) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            .help(url?.lastPathComponent ?? "")
    }
}
