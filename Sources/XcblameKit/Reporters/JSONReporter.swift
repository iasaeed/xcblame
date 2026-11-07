import Foundation

/// Serializes a `ReportDocument`: sorted keys, ISO-8601 dates, unescaped slashes, so two runs over the same input
/// are byte-equal.
public enum JSONReporter {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func render(_ document: ReportDocument) throws -> Data {
        try encoder().encode(document) + Data("\n".utf8)
    }

    public static func renderString(_ document: ReportDocument) throws -> String {
        String(decoding: try render(document), as: UTF8.self)
    }
}
