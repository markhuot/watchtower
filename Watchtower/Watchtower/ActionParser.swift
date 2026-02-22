import Foundation
import os

/// Parses action script files for annotation metadata.
class ActionParser {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.eyes.Watchtower",
        category: "ActionParser"
    )

    /// Comment prefixes recognized by the parser.
    private static let commentPrefixes = ["#", "//"]

    /// Parse a single action file and return an Action, or nil if the file can't be read.
    static func parse(filePath: String, isGlobal: Bool) -> Action? {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: filePath) else {
            logger.warning("Action file not readable: \(filePath)")
            return nil
        }

        let filename = (filePath as NSString).lastPathComponent
        let ext = (filename as NSString).pathExtension
        let fileExtension: String? = ext.isEmpty ? nil : ext

        // Check executable bit
        let isExecutable = fm.isExecutableFile(atPath: filePath)

        // Read the first 50 lines for annotations
        let annotations = readAnnotations(from: filePath)

        // Extract metadata
        let customName = annotations.first(where: { $0.type == .name })?.value
        let descriptionText = annotations.first(where: { $0.type == .description })?.value

        // Derive display name from filename if no @name annotation
        let displayName = customName ?? deriveDisplayName(from: filename)

        // Extract arguments (in declaration order)
        var arguments: [ActionArgument] = []
        var defaults: [String: String] = [:]
        var options: [String: String] = [:]

        for annotation in annotations {
            switch annotation.type {
            case .argument:
                if let (varName, label) = parseArgumentValue(annotation.value) {
                    arguments.append(ActionArgument(
                        id: varName,
                        variableName: varName,
                        label: label
                    ))
                }
            case .defaultValue:
                if let (varName, value) = parseKeyValueAnnotation(annotation.value) {
                    defaults[varName] = value
                }
            case .options:
                if let (varName, value) = parseKeyValueAnnotation(annotation.value) {
                    options[varName] = value
                }
            case .name, .description:
                break  // Already handled
            }
        }

        return Action(
            id: filename,
            displayName: displayName,
            descriptionText: descriptionText,
            scriptPath: filePath,
            arguments: arguments,
            defaults: defaults,
            options: options,
            isGlobal: isGlobal,
            isExecutable: isExecutable,
            fileExtension: fileExtension
        )
    }

    // MARK: - Display Name Derivation

    /// Derive a display name from a filename.
    /// Strips the extension, replaces hyphens and underscores with spaces, title-cases.
    static func deriveDisplayName(from filename: String) -> String {
        // Remove extension
        let nameWithoutExt: String
        if let dotRange = filename.lastIndex(of: ".") {
            nameWithoutExt = String(filename[filename.startIndex..<dotRange])
        } else {
            nameWithoutExt = filename
        }

        // Replace hyphens and underscores with spaces
        let spaced = nameWithoutExt
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        // Title-case each word
        return spaced.split(separator: " ")
            .map { word in
                var w = String(word)
                if let first = w.first {
                    w = String(first).uppercased() + w.dropFirst()
                }
                return w
            }
            .joined(separator: " ")
    }

    // MARK: - Annotation Parsing

    private enum AnnotationType {
        case name
        case description
        case argument
        case defaultValue
        case options
    }

    private struct Annotation {
        let type: AnnotationType
        let value: String
    }

    /// Read the first 50 lines of the file and extract annotations.
    /// Stops at the first non-comment, non-blank, non-shebang line.
    private static func readAnnotations(from filePath: String) -> [Annotation] {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var annotations: [Annotation] = []
        let lines = content.components(separatedBy: .newlines)
        let maxLines = min(lines.count, 50)

        for i in 0..<maxLines {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            // Skip blank lines
            if line.isEmpty { continue }

            // Skip shebang
            if line.hasPrefix("#!") { continue }

            // Try to match a comment prefix
            var commentBody: String? = nil
            for prefix in commentPrefixes {
                if line.hasPrefix(prefix) {
                    let afterPrefix = String(line.dropFirst(prefix.count))
                    commentBody = afterPrefix.trimmingCharacters(in: .whitespaces)
                    break
                }
            }

            guard let body = commentBody else {
                // Non-comment, non-blank line = end of annotations
                break
            }

            // Match annotation patterns
            if let annotation = matchAnnotation(body) {
                annotations.append(annotation)
            }
        }

        return annotations
    }

    /// Match a comment body against known annotation patterns.
    private static func matchAnnotation(_ body: String) -> Annotation? {
        if body.hasPrefix("@name ") {
            let value = String(body.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return Annotation(type: .name, value: value)
        }
        if body.hasPrefix("@description ") {
            let value = String(body.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            return Annotation(type: .description, value: value)
        }
        if body.hasPrefix("@argument ") {
            let value = String(body.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            return Annotation(type: .argument, value: value)
        }
        if body.hasPrefix("@default ") {
            let value = String(body.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            return Annotation(type: .defaultValue, value: value)
        }
        if body.hasPrefix("@options ") {
            let value = String(body.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            return Annotation(type: .options, value: value)
        }
        return nil
    }

    /// Parse an @argument value: "VARIABLE_NAME The human-readable label"
    /// Returns (variableName, label) or nil if malformed.
    private static func parseArgumentValue(_ value: String) -> (String, String)? {
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let varName = String(parts[0])
        let label = String(parts[1]).trimmingCharacters(in: .whitespaces)
        return (varName, label)
    }

    /// Parse a key-value annotation: "VARIABLE_NAME some value"
    /// Returns (variableName, value) or nil if malformed.
    private static func parseKeyValueAnnotation(_ value: String) -> (String, String)? {
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let varName = String(parts[0])
        let val = String(parts[1]).trimmingCharacters(in: .whitespaces)
        return (varName, val)
    }
}
