import Foundation
import zlib

/// Result of inflating a gzip stream. A truncated or corrupt stream keeps every byte inflated before the damage.
public struct InflateResult: Sendable, Equatable {
    public var bytes: [UInt8]
    /// The stream ended before the gzip trailer, or zlib reported corrupt data (bad block, CRC32 or ISIZE mismatch).
    /// Callers mark the report `degraded: truncated` (DESIGN §5.2).
    public var truncated: Bool
    /// The trailer CRC32 and ISIZE matched the inflated bytes.
    public var trailerVerified: Bool
    /// zlib's message for a corrupt stream, when it gave one.
    public var errorDetail: String?
    /// Inflating stopped at the byte cap (gzip bomb or a log beyond the memory budget); `truncated` is set too.
    public var capReached: Bool

    public init(bytes: [UInt8], truncated: Bool, trailerVerified: Bool, errorDetail: String? = nil,
                capReached: Bool = false) {
        self.bytes = bytes
        self.truncated = truncated
        self.trailerVerified = trailerVerified
        self.errorDetail = errorDetail
        self.capReached = capReached
    }
}

public enum GzipError: Error, Sendable, Equatable {
    /// The input does not start with a gzip header (`1f 8b 08`).
    case notGzip
    /// zlib refused to initialize.
    case zlibInit(Int32)
}

/// Streaming gzip inflater over the SDK's zlib (gzip mode, `windowBits = 15 + 16`). zlib parses the header (FEXTRA,
/// FNAME, FCOMMENT, FHCRC) and checks the trailer CRC32 and ISIZE before reporting the end of the stream.
///
/// Feed input in chunks with `feed(_:sink:)`; inflated bytes go to `sink` in chunks. Not shareable across threads:
/// the `z_stream` lives at a fixed heap address because zlib keeps a pointer back to it.
public final class InflateStream {
    public enum Status: Sendable, Equatable {
        /// More input is needed.
        case needsInput
        /// The gzip trailer was read and verified; further input is ignored.
        case finished
        /// Corrupt data; further input is ignored.
        case failed(String)
    }

    public private(set) var status: Status = .needsInput
    /// Set by `stop()`: no further output is produced, even within the current `feed`.
    private var stopRequested = false
    private let stream: UnsafeMutablePointer<z_stream>
    private var output: [UInt8]
    /// `inflateInit2_` succeeded, so `deinit` must call `inflateEnd`. `deinit` alone frees the pointer (it also runs
    /// when `init` throws after every property is set), so the error path must not.
    private var zlibInitialized = false

    public init(outputChunkSize: Int = 1 << 18) throws(GzipError) {
        stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        output = [UInt8](repeating: 0, count: max(outputChunkSize, 1024))
        let rc = inflateInit2_(stream, MAX_WBITS + 16, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw .zlibInit(rc) }
        zlibInitialized = true
    }

    deinit {
        if zlibInitialized { inflateEnd(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    /// Inflates `chunk`, handing every produced byte range to `sink`. Returns the status after the chunk.
    @discardableResult
    public func feed(_ chunk: UnsafeRawBufferPointer, sink: (UnsafeBufferPointer<UInt8>) -> Void) -> Status {
        guard status == .needsInput, !stopRequested, let base = chunk.baseAddress, !chunk.isEmpty else { return status }
        stream.pointee.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: Bytef.self))
        stream.pointee.avail_in = uInt(chunk.count)
        defer {
            stream.pointee.next_in = nil
            stream.pointee.avail_in = 0
        }
        let outCount = output.count
        output.withUnsafeMutableBufferPointer { out in
            guard let outBase = out.baseAddress else { return }
            while status == .needsInput, !stopRequested {
                stream.pointee.next_out = outBase
                stream.pointee.avail_out = uInt(outCount)
                let rc = inflate(stream, Z_NO_FLUSH)
                let produced = outCount - Int(stream.pointee.avail_out)
                if produced > 0 { sink(UnsafeBufferPointer(start: outBase, count: produced)) }
                switch rc {
                case Z_STREAM_END:
                    status = .finished
                case Z_OK:
                    if stream.pointee.avail_in == 0 && produced < outCount { return }
                case Z_BUF_ERROR:
                    // No progress possible: input exhausted mid-stream.
                    return
                default:
                    status = .failed(Self.message(stream.pointee.msg, rc: rc))
                }
            }
            stream.pointee.next_out = nil
            stream.pointee.avail_out = 0
        }
        return status
    }

    /// Stops inflating; callable from a `feed` sink. The status stays as it was (not `finished`).
    public func stop() { stopRequested = true }

    private static func message(_ msg: UnsafePointer<CChar>?, rc: Int32) -> String {
        guard let msg else { return "zlib error \(rc)" }
        return String(cString: msg)
    }
}

/// Whole-file helpers over `InflateStream`.
public enum GzipFile {
    /// Input is fed to zlib in chunks of this size.
    static let inputChunkSize = 1 << 20
    /// Inflated bytes kept at most (R8, DESIGN §4.3 rule 5); beyond it the result is `truncated` + `capReached`.
    public static let defaultMaxBytes = 2 << 30

    public static func isGzip<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
        var it = bytes.makeIterator()
        return it.next() == 0x1f && it.next() == 0x8b && it.next() == 0x08
    }

    /// Inflates a whole gzip file. Throws only when the file cannot be read or is not gzip.
    public static func inflate(contentsOf url: URL) throws -> InflateResult {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try inflate(data)
    }

    /// Inflates a gzip buffer. A truncated or corrupt stream returns the bytes inflated so far with `truncated`; more
    /// than `maxBytes` stops at the cap with `truncated` and `capReached`.
    public static func inflate(_ data: Data, maxBytes: Int = defaultMaxBytes) throws(GzipError) -> InflateResult {
        guard isGzip(data) else { throw .notGzip }
        let cap = max(maxBytes, 0)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(sizeHint(data), cap))
        var capped = false
        let status = try run(data) { chunk in
            let room = cap - bytes.count
            guard chunk.count <= room else {
                bytes.append(contentsOf: chunk.prefix(room))
                capped = true
                return false
            }
            bytes.append(contentsOf: chunk)
            return true
        }
        if capped {
            return InflateResult(bytes: bytes, truncated: true, trailerVerified: false,
                                 errorDetail: "inflate cap of \(cap) bytes reached", capReached: true)
        }
        return result(bytes: bytes, status: status)
    }

    /// Integrity probe for the Locator (DESIGN §5.2): true when the stream inflates to its end and the trailer CRC32
    /// and ISIZE verify. Inflated bytes are discarded as they are produced.
    public static func verifyTrailer(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), isGzip(data),
              let status = try? run(data, sink: { _ in true }) else { return false }
        return status == .finished
    }

    static func result(bytes: [UInt8], status: InflateStream.Status) -> InflateResult {
        switch status {
        case .finished:
            return InflateResult(bytes: bytes, truncated: false, trailerVerified: true)
        case .needsInput:
            return InflateResult(bytes: bytes, truncated: true, trailerVerified: false,
                                 errorDetail: "gzip stream ended before its trailer")
        case let .failed(message):
            return InflateResult(bytes: bytes, truncated: true, trailerVerified: false, errorDetail: message)
        }
    }

    /// `sink` returns false to stop inflating.
    private static func run(_ data: Data, sink: (UnsafeBufferPointer<UInt8>) -> Bool) throws(GzipError)
        -> InflateStream.Status {
        let stream = try InflateStream()
        var offset = data.startIndex
        var stopped = false
        while offset < data.endIndex, stream.status == .needsInput, !stopped {
            let end = min(offset + inputChunkSize, data.endIndex)
            _ = data[offset..<end].withUnsafeBytes { buffer in
                stream.feed(buffer) { chunk in
                    if !sink(chunk) {
                        stopped = true
                        stream.stop()
                    }
                }
            }
            offset = end
        }
        return stream.status
    }

    /// ISIZE from the trailer (inflated size mod 2^32), used only as a capacity hint and capped.
    private static func sizeHint(_ data: Data) -> Int {
        guard data.count >= 18 else { return 0 }
        let tail = data.suffix(4)
        var size = 0
        for (shift, byte) in tail.enumerated() { size |= Int(byte) << (8 * shift) }
        let cap = 1 << 30
        return size >= data.count ? min(size, cap) : 0
    }
}
