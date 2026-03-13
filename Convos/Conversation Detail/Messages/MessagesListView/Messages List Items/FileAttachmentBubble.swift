import ConvosCore
import SwiftUI
import UniformTypeIdentifiers

struct FileAttachmentBubble: View {
    let attachment: HydratedAttachment
    let style: MessageBubbleType
    let isOutgoing: Bool
    let profile: Profile

    private var textColor: Color {
        isOutgoing ? .colorTextPrimaryInverted : .colorTextPrimary
    }

    private var secondaryTextColor: Color {
        isOutgoing ? .colorTextPrimaryInverted.opacity(0.7) : .secondary
    }

    private var iconBackground: Color {
        isOutgoing ? .white.opacity(0.2) : .colorFillMinimal
    }

    private var iconForeground: Color {
        isOutgoing ? .colorTextPrimaryInverted.opacity(0.8) : .secondary
    }

    var body: some View {
        MessageContainer(style: style, isOutgoing: isOutgoing) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                fileIcon
                    .frame(width: 44, height: 44)
                    .accessibilityIdentifier("file-attachment-icon")

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayFilename)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(textColor)
                        .lineLimit(2)
                        .accessibilityIdentifier("file-attachment-filename")

                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                        .accessibilityIdentifier("file-attachment-subtitle")
                }

                Spacer(minLength: 0)
            }
            .padding(DesignConstants.Spacing.step3x)
        }
        .accessibilityIdentifier("file-attachment-bubble")
        .accessibilityLabel("File: \(displayFilename)")
    }

    private var displayFilename: String {
        attachment.filename ?? "Unknown file"
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let label = attachment.fileTypeLabel {
            parts.append(label)
        } else if let ext = attachment.filenameExtension {
            parts.append(ext.uppercased())
        }
        if let size = attachment.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if parts.isEmpty {
            return "File"
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var fileIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(iconBackground)
            Image(systemName: fileIconSymbol)
                .font(.system(size: 20))
                .foregroundStyle(iconForeground)
        }
    }

    private var fileIconSymbol: String {
        if let ext = attachment.filenameExtension {
            switch ext {
            case "pdf":
                return "doc.text.fill"
            case "txt", "rtf", "rtfd":
                return "doc.plaintext.fill"
            case "md", "markdown":
                return "doc.text.fill"
            case "csv":
                return "tablecells.fill"
            case "json", "yaml", "yml", "xml":
                return "curlybraces"
            case "html", "htm":
                return "globe"
            case "zip", "tar", "gz", "rar", "7z":
                return "doc.zipper"
            case "swift", "py", "js", "ts", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "m", "cs":
                return "chevron.left.forwardslash.chevron.right"
            case "doc", "docx":
                return "doc.text.fill"
            case "xls", "xlsx", "numbers":
                return "tablecells.fill"
            case "ppt", "pptx", "key", "keynote":
                return "rectangle.fill.on.rectangle.angled.fill"
            default:
                break
            }
        }

        if let mimeType = attachment.mimeType {
            if mimeType.hasPrefix("text/") { return "doc.plaintext.fill" }
            if mimeType.hasPrefix("application/json") { return "curlybraces" }
            if mimeType.hasPrefix("application/pdf") { return "doc.text.fill" }
            if mimeType.contains("spreadsheet") || mimeType.contains("csv") { return "tablecells.fill" }
            if mimeType.contains("presentation") { return "rectangle.fill.on.rectangle.angled.fill" }
            if mimeType.contains("word") || mimeType.contains("document") { return "doc.text.fill" }
        }

        return "doc.fill"
    }
}
