import Foundation
import PDFKit

/// A file the user brought into a chat.
///
/// Attachments land in the chat's own folder rather than being read where they
/// sit. Two reasons: the chat's folder is its working directory, so the
/// assistant can `read_file` and `update_file` an attachment like anything
/// else it made; and deleting the chat then takes the copy with it, which is
/// only true of files Dictator put there.
///
/// `text` is extracted **once, at attach time**, and stored. It is not derived
/// when the prompt is built: every round re-renders the whole thread, so a
/// PDF would be re-parsed and an image re-described on each one — turning a
/// three-round tool loop into three vision passes.
struct ChatAttachment: Codable, Hashable, Sendable, Identifiable {
    /// What kind of thing this is, which decides how it reaches the model.
    enum Kind: String, Codable, Sendable {
        /// Readable as text, and handed over verbatim.
        case text
        /// A PDF, handed over as the text PDFKit could pull out of it.
        case pdf
        /// An image, handed over as the vision model's description of it.
        case image
        /// Something we can't turn into words. The model is told it exists and
        /// what it's called, which is enough for it to ask about.
        case other
    }

    var id: String { path }

    var name: String
    var path: String
    var byteCount: Int
    var kind: Kind
    /// What the model is given in place of the file. nil when extraction found
    /// nothing or couldn't run — `note` then says why.
    var text: String?
    /// Shown to the user and told to the model when there's no text: "this is a
    /// PDF of scanned pages", "the loaded model can't see images".
    var note: String?
    /// True when `text` is the opening of a longer file rather than all of it.
    var truncated: Bool = false

    var url: URL { URL(fileURLWithPath: path) }


    var stillExists: Bool { FileManager.default.fileExists(atPath: path) }
    var fileExtension: String { url.pathExtension.lowercased() }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var symbol: String {
        switch kind {
        case .text: "doc.text"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .other: "doc"
        }
    }
}

/// Copies files into a chat's folder and works out what the model can be told
/// about them.
@MainActor
enum ChatAttachments {
    /// Largest file that may be attached. Generous for a document, and a bound
    /// on someone dragging a disk image onto the window by accident.
    nonisolated static let maximumBytes = 25 * 1024 * 1024

    /// How much of one attachment is inlined into the prompt.
    ///
    /// Roughly 5K tokens — enough for a long document, small enough that three
    /// attachments can't eat a 32K window before the user's question. Past
    /// this the model is told to use `read_file`, which it can, because the
    /// file is sitting in its working directory.
    nonisolated static let inlineCharacterLimit = 20_000

    enum Failure: LocalizedError {
        case tooLarge(name: String)
        case unreadable(name: String)
        case noFolder

        var errorDescription: String? {
            switch self {
            case .tooLarge(let name):
                "\(name) is too big to attach (the limit is 25 MB)."
            case .unreadable(let name):
                "Couldn't read \(name)."
            case .noFolder:
                "Couldn't make this chat's folder."
            }
        }
    }

    /// Copies one file in and extracts whatever the model can be given.
    ///
    /// A copy, not a move or a reference: the original is the user's, stays
    /// where it is, and is not deleted when the chat is. A file of the same
    /// name already in the folder gets a numbered sibling rather than being
    /// overwritten — attaching the same thing twice is a mistake to survive,
    /// not to punish.
    static func attach(_ source: URL, to thread: ChatThread) async throws -> ChatAttachment {
        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { throw Failure.unreadable(name: source.lastPathComponent) }
        let size = values?.fileSize ?? 0
        guard size <= maximumBytes else { throw Failure.tooLarge(name: source.lastPathComponent) }

        guard let folder = try? ChatFiles.folder(for: thread) else { throw Failure.noFolder }

        // The user picked this file, so its name is theirs — but it still has
        // to be a plain filename landing inside the folder, never a path.
        let safeName = source.lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let base = folder.url.appendingPathComponent(
            safeName.hasPrefix(".") ? "file" + safeName : safeName)
        let destination = ChatFileWriter.availableURL(for: base)

        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw Failure.unreadable(name: source.lastPathComponent)
        }

        var attachment = ChatAttachment(
            name: destination.lastPathComponent,
            path: destination.path,
            byteCount: size,
            kind: kind(of: destination))
        await extract(into: &attachment)
        return attachment
    }

    // MARK: - Classifying

    nonisolated private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp",
    ]

    /// Decided by extension first, then by looking at the bytes.
    ///
    /// The sniff matters: people attach `.log`, `.env`, `.csv.bak` and files
    /// with no extension at all, and all of them are text. Anything that
    /// decodes as UTF-8 and has no NUL byte in its first chunk is text,
    /// whatever it's called.
    nonisolated static func kind(of url: URL) -> ChatAttachment.Kind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        return looksLikeText(url) ? .text : .other
    }

    nonisolated private static func looksLikeText(_ url: URL) -> Bool {
        // An empty file is text — an empty one. Checked by size rather than by
        // reading, because `read(upToCount:)` returns nil at EOF and an empty
        // file is indistinguishable from an unreadable one that way. Telling
        // someone their empty .txt is "not a text file" is just confusing.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == 0 {
            return true
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let sample = try? handle.read(upToCount: 4096), !sample.isEmpty else { return false }
        guard !sample.contains(0) else { return false }
        return String(data: sample, encoding: .utf8) != nil
    }

    /// What a file can be turned into without the model's help.
    ///
    /// Everything but images, which need a vision pass and therefore the main
    /// actor. Split out so it can be exercised headlessly — the failure mode
    /// here is a file that looks attached and silently contributes nothing.
    nonisolated static func readWithoutModel(
        _ url: URL, kind: ChatAttachment.Kind
    ) -> (text: String?, note: String?, truncated: Bool) {
        switch kind {
        case .text:
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                return (nil, "couldn't be read as text", false)
            }
            guard !contents.isEmpty else { return (nil, "is empty", false) }
            return capped(contents)

        case .pdf:
            guard let document = PDFDocument(url: url) else {
                return (nil, "couldn't be opened as a PDF", false)
            }
            var out = ""
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index),
                      let pageText = page.string, !pageText.isEmpty else { continue }
                out += "\n\n[Page \(index + 1)]\n" + pageText
                if out.count > inlineCharacterLimit { break }
            }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // Overwhelmingly a scan. Saying so is far more use than an
                // empty string, which the model reads as an empty document.
                let pages = document.pageCount
                return (nil, "\(pages) page\(pages == 1 ? "" : "s") with no selectable "
                        + "text — probably a scan", false)
            }
            return capped(trimmed)

        case .image:
            return (nil, nil, false)   // needs the model; see `extract`.

        case .other:
            return (nil, "not a text, PDF or image file, so its contents can't be read", false)
        }
    }

    nonisolated private static func capped(
        _ text: String
    ) -> (text: String?, note: String?, truncated: Bool) {
        text.count > inlineCharacterLimit
            ? (String(text.prefix(inlineCharacterLimit)), nil, true)
            : (text, nil, false)
    }

    // MARK: - Extracting

    private static func extract(into attachment: inout ChatAttachment) async {
        guard attachment.kind == .image else {
            let result = readWithoutModel(attachment.url, kind: attachment.kind)
            attachment.text = result.text
            attachment.note = result.note
            attachment.truncated = result.truncated
            return
        }

        // The same vision-to-prose path `read_screen` uses. Chat models here
        // are handed text, not images, so an image becomes a description of
        // itself — written once and stored, never on re-render.
        guard WindowVisionContext.canReadImages else {
            attachment.note = "nothing on this Mac can read images right now"
            return
        }
        guard let image = loadImage(attachment.url) else {
            attachment.note = "couldn't be opened as an image"
            return
        }
        do {
            let description = try await WindowVisionContext.readImage(
                image,
                systemPrompt: """
                    You are looking at an image the user has attached to a conversation. \
                    Describe what it shows and transcribe any text in it, exactly as \
                    written. Be factual and specific. Do not guess at anything you \
                    cannot see.
                    """,
                userPrompt: "Describe this image and transcribe the text in it.",
                maxTokens: 700)
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                attachment.note = "the model couldn't make anything of this image"
            } else {
                attachment.text = trimmed
            }
        } catch {
            attachment.note = "couldn't be read: \(error.localizedDescription)"
        }
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// Decoding lives in an extension on purpose: an `init` declared in the type
// body suppresses the memberwise initialiser, and `ChatAttachment` is
// constructed memberwise in `ChatAttachments.attach`.
extension ChatAttachment {
    /// Hand-written for the reason on `ChatMessage.init(from:)`: a synthesised
    /// decoder treats `truncated` as required because it carries a default, and
    /// one missing key throws away every thread in the file.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "attachment"
        path = try c.decode(String.self, forKey: .path)
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .other
        text = try c.decodeIfPresent(String.self, forKey: .text)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}
