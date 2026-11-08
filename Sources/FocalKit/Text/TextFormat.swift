import UniformTypeIdentifiers

/// How a text window treats its file. Markdown is plain text on disk (same bytes, same editor) that can also be
/// shown rendered; rich text (RTF/RTFD) keeps fonts and styles and is never flattened to plain.
public enum TextFormat: Equatable, Sendable {
    case plain, markdown, rich

    public static let markdownType = "net.daringfireball.markdown"
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext"]

    /// The extension wins over the type for Markdown: a new file saved as "notes.md" from the plain-text format
    /// keeps the plain-text type name but is Markdown to the person who named it.
    public init(typeName: String?, url: URL?) {
        if let type = typeName.flatMap(UTType.init), Self.isRich(type) {
            self = .rich
        } else if let ext = url?.pathExtension.lowercased(), Self.markdownExtensions.contains(ext) {
            self = .markdown
        } else if let type = typeName.flatMap(UTType.init), let markdown = UTType(Self.markdownType), type.conforms(to: markdown) {
            self = .markdown
        } else {
            self = .plain
        }
    }

    public static func isRich(_ type: UTType) -> Bool {
        type.conforms(to: .rtf) || type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD)
    }

    public static func isRichPackage(_ typeName: String) -> Bool {
        UTType(typeName)?.conforms(to: .rtfd) ?? false
    }
}
