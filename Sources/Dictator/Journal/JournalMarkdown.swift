import Foundation

/// The little bit of Markdown the journal window has to understand: which
/// lines of an entry are words and which are photos.
///
/// Deliberately not a Markdown parser. `ChatMarkdown` already splits fenced
/// code from prose for the chat, and `AttributedString(markdown:)` handles
/// everything inline; the only thing neither can do is tell us that a line is
/// an image so the window can draw the photo instead of a link. That is the
/// whole job here.
enum JournalMarkdown {

    /// One `![alt](reference)` found on a line of its own.
    struct ImageRef: Identifiable, Equatable {
        let alt: String
        /// Exactly as written in the file. Kept verbatim so putting an entry
        /// back together can't rewrite somebody's link.
        let reference: String
        /// The line as it appeared, so an unchanged entry round-trips byte for
        /// byte.
        let line: String

        var id: String { line }
    }

    /// An image reference and the file it points at, if it still exists.
    struct ResolvedImage: Identifiable, Equatable {
        let ref: ImageRef
        let url: URL?

        var id: String { ref.line }
    }

    /// What the day view draws, in order.
    ///
    /// Photos arrive as one block rather than one each: several taken at the
    /// same moment are one thing that happened, and stacking them full-width
    /// down the page turns a morning into a scroll. The day view lays a group
    /// out as a grid.
    enum Block: Identifiable {
        case prose(String)
        case images([ResolvedImage])

        var id: String {
            switch self {
            case .prose(let text): return "p:\(text.prefix(48))"
            case .images(let images): return "i:\(images.map(\.id).joined(separator: "|"))"
            }
        }
    }

    /// Split an entry body into the blocks that render it.
    ///
    /// `note` is the file the entry came from — image references are relative
    /// to it. A reference that doesn't resolve still produces a block, with a
    /// nil URL, so the window can say "this photo has moved" rather than
    /// quietly showing nothing where a picture used to be.
    static func blocks(in body: String, note: URL) -> [Block] {
        var blocks: [Block] = []
        var prose: [String] = []
        var run: [ResolvedImage] = []

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            prose.removeAll()
            guard !text.isEmpty else { return }
            blocks.append(.prose(text))
        }

        func flushImages() {
            guard !run.isEmpty else { return }
            blocks.append(.images(run))
            run.removeAll()
        }

        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let ref = imageRef(in: text) {
                flushProse()
                run.append(ResolvedImage(
                    ref: ref, url: JournalAttachments.resolve(ref.reference, relativeTo: note)))
            } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line between two photos doesn't start a new group —
                // it's just how the file was written.
                if run.isEmpty { prose.append(text) }
            } else {
                flushImages()
                prose.append(text)
            }
        }
        flushProse()
        flushImages()
        return blocks
    }

    /// The prose of an entry, with the image lines taken out.
    ///
    /// This is what the editor puts in its text box: someone fixing a typo
    /// should not have to look at, or accidentally break, a link they never
    /// typed.
    static func prose(in body: String) -> String {
        body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { imageRef(in: String($0)) == nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every image line in an entry, in order.
    static func images(in body: String) -> [ImageRef] {
        body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { imageRef(in: String($0)) }
    }

    /// Put an entry back together from edited prose and the photos it keeps.
    ///
    /// Photos go under the words, which is the shape every entry this app
    /// writes already has. An entry whose photos were hand-interleaved between
    /// paragraphs will have them gathered at the end when it's edited here —
    /// the one transformation this window makes to a file it didn't write, and
    /// the alternative (splicing around each image line) reorders text instead,
    /// which is worse.
    static func assemble(prose: String, images: [ImageRef]) -> String {
        let words = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = images.map(\.line)
        if lines.isEmpty { return words }
        if words.isEmpty { return lines.joined(separator: "\n") }
        return words + "\n\n" + lines.joined(separator: "\n")
    }

    /// An image on a line of its own: optional whitespace, `![alt](ref)`,
    /// optional whitespace, and nothing else.
    ///
    /// Line-at-a-time on purpose. An image *inside* a sentence is part of that
    /// sentence and stays in the prose, where the inline Markdown renderer
    /// deals with it; pulling it out would break the paragraph in half.
    static func imageRef(in line: String) -> ImageRef? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")") else { return nil }
        guard let altEnd = trimmed.firstIndex(of: "]") else { return nil }
        let afterAlt = trimmed.index(after: altEnd)
        guard afterAlt < trimmed.endIndex, trimmed[afterAlt] == "(" else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<altEnd])
        let reference = String(trimmed[trimmed.index(after: afterAlt)..<trimmed.index(before: trimmed.endIndex)])
        guard !reference.isEmpty, !reference.contains(")") else { return nil }
        return ImageRef(alt: alt, reference: reference, line: line)
    }
}
