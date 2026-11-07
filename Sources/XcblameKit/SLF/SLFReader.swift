import Foundation

public enum SLFReadError: Error, Sendable, Equatable {
    /// Neither a gzip stream nor an inflated `SLF0` log.
    case notSLF
    /// The gzip stream inflated to nothing usable (shorter than the `SLF0` header).
    case empty
}

/// `.xcactivitylog` reader: gzip -> tokens -> `RawLog` (reader `.slf`).
public struct SLFReader {
    public static func read(url: URL, table: ClassSchemaTable = .v1) throws -> RawLog {
        try read(data: Data(contentsOf: url, options: .mappedIfSafe), table: table)
    }

    /// Accepts a gzip stream or an already inflated log. A truncated or corrupt gzip stream is decoded as far as it
    /// inflated and carries a `truncated` warning (callers mark the report `degraded: truncated`).
    public static func read(data: Data, table: ClassSchemaTable = .v1,
                            maxInflateBytes: Int = GzipFile.defaultMaxBytes) throws -> RawLog {
        if data.starts(with: SLFTokenizer.header) {
            return SLFDecoder.decode(bytes: [UInt8](data), table: table)
        }
        guard GzipFile.isGzip(data) else { throw SLFReadError.notSLF }
        let inflated = try GzipFile.inflate(data, maxBytes: maxInflateBytes)
        guard inflated.bytes.count >= SLFTokenizer.header.count else { throw SLFReadError.empty }
        guard inflated.bytes.starts(with: SLFTokenizer.header) else { throw SLFReadError.notSLF }
        var log = SLFDecoder.decode(bytes: inflated.bytes, table: table)
        if inflated.truncated {
            let detail = "gzip: " + (inflated.errorDetail ?? "stream truncated")
                + "; \(inflated.bytes.count) bytes inflated"
            log.decodeWarnings.insert(DecodeWarning(kind: .truncated, detail: detail, offset: inflated.bytes.count),
                                      at: 0)
        }
        if inflated.capReached {
            log.decodeWarnings.insert(DecodeWarning(kind: .inflateCapReached, detail: "stopped inflating at "
                + "\(inflated.bytes.count) bytes (memory cap); the rest of the log was not read"), at: 0)
        }
        return log
    }
}

extension RawLog {
    /// True when the reader saw a truncated or corrupt input and returned a partial tree.
    public var isTruncated: Bool { decodeWarnings.contains { $0.kind == .truncated } }
}
