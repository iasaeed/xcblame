import Foundation
import XCTest
import zlib
@testable import XcblameKit

final class GzipTests: XCTestCase {
    func testInflatesFixtureAndVerifiesTrailer() throws {
        let result = try GzipFile.inflate(contentsOf: SLFFixtures.cli26Clean)
        XCTAssertEqual(result.bytes.count, 12_497_589)
        XCTAssertFalse(result.truncated)
        XCTAssertTrue(result.trailerVerified)
        XCTAssertTrue(result.bytes.starts(with: Array("SLF011#".utf8)))
        XCTAssertTrue(GzipFile.verifyTrailer(at: SLFFixtures.cli26Clean))
    }

    func testEveryFixtureVerifies() {
        for url in SLFFixtures.allLogs {
            XCTAssertTrue(GzipFile.verifyTrailer(at: url), url.lastPathComponent)
        }
    }

    func testStreamingInChunksMatchesWholeInflate() throws {
        let data = try Data(contentsOf: SLFFixtures.cli27Clean)
        let whole = try GzipFile.inflate(data)
        let stream = try InflateStream(outputChunkSize: 1000)
        var out: [UInt8] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + 4093, data.count)
            data[offset..<end].withUnsafeBytes { _ = stream.feed($0) { out.append(contentsOf: $0) } }
            offset = end
        }
        XCTAssertEqual(stream.status, .finished)
        XCTAssertEqual(out, whole.bytes)
        XCTAssertEqual(out.count, 13_428_173)
    }

    func testCorruptTrailerKeepsBytesAndFailsVerification() throws {
        var data = try Data(contentsOf: SLFFixtures.cli26Clean)
        let crcIndex = data.count - 8
        data[crcIndex] ^= 0xff
        let result = try GzipFile.inflate(data)
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.trailerVerified)
        XCTAssertEqual(result.bytes.count, 12_497_589)
        XCTAssertNotNil(result.errorDetail)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-corrupt-\(UUID()).gz")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(GzipFile.verifyTrailer(at: url))
    }

    func testTruncatedStreamReturnsPartialBytes() throws {
        let data = try Data(contentsOf: SLFFixtures.cli26Clean)
        let full = try GzipFile.inflate(data).bytes
        let cut = try GzipFile.inflate(data.prefix(data.count / 2))
        XCTAssertTrue(cut.truncated)
        XCTAssertFalse(cut.trailerVerified)
        XCTAssertGreaterThan(cut.bytes.count, 0)
        XCTAssertEqual(Array(full.prefix(cut.bytes.count)), cut.bytes)
        // Missing only the 8-byte trailer: all bytes, still not verified.
        let noTrailer = try GzipFile.inflate(data.prefix(data.count - 8))
        XCTAssertTrue(noTrailer.truncated)
        XCTAssertEqual(noTrailer.bytes.count, full.count)
    }

    func testRejectsNonGzip() {
        XCTAssertThrowsError(try GzipFile.inflate(Data("SLF011#".utf8))) { error in
            XCTAssertEqual(error as? GzipError, .notGzip)
        }
        XCTAssertFalse(GzipFile.verifyTrailer(at: URL(fileURLWithPath: "/nonexistent/x.xcactivitylog")))
    }

    // MARK: Inflate cap (code review v0.1 row 8)

    /// gzip of `megabytes` MB of zeros (about 1000:1), compressed in 1 MB pieces.
    static func zeroBomb(megabytes: Int) throws -> Data {
        var stream = z_stream()
        let rc = deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 9, Z_DEFAULT_STRATEGY,
                               zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw GzipError.zlibInit(rc) }
        defer { deflateEnd(&stream) }
        var zeros = [UInt8](repeating: 0, count: 1 << 20)
        var out = [UInt8](repeating: 0, count: 1 << 16)
        var result = Data()
        for piece in 0..<megabytes {
            let flush = piece == megabytes - 1 ? Z_FINISH : Z_NO_FLUSH
            zeros.withUnsafeMutableBufferPointer { input in
                stream.next_in = input.baseAddress
                stream.avail_in = uInt(input.count)
                repeat {
                    out.withUnsafeMutableBufferPointer { output in
                        stream.next_out = output.baseAddress
                        stream.avail_out = uInt(output.count)
                        _ = deflate(&stream, flush)
                        if let base = output.baseAddress {
                            result.append(base, count: output.count - Int(stream.avail_out))
                        }
                    }
                } while stream.avail_out == 0
            }
        }
        return result
    }

    func testGzipBombStopsAtTheCap() throws {
        let bomb = try Self.zeroBomb(megabytes: 256)
        XCTAssertLessThan(bomb.count, 1 << 20)
        let cap = 64 << 20
        let result = try GzipFile.inflate(bomb, maxBytes: cap)
        XCTAssertTrue(result.capReached)
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.trailerVerified)
        XCTAssertEqual(result.bytes.count, cap)
        XCTAssertLessThanOrEqual(result.bytes.capacity, cap + (1 << 20), "never grows past the cap")
        // The whole stream still inflates below a larger cap.
        XCTAssertFalse(try GzipFile.inflate(try Self.zeroBomb(megabytes: 2), maxBytes: cap).capReached)
    }

    func testCappedSLFLogIsTruncated() throws {
        let raw = try SLFReader.read(data: try Data(contentsOf: SLFFixtures.cli26Clean), maxInflateBytes: 1 << 20)
        XCTAssertTrue(raw.isTruncated)
        XCTAssertEqual(raw.decodeWarnings.first?.kind, .inflateCapReached)
        XCTAssertTrue(BuildModelBuilder.build(raw, reader: .slf).degradations.contains { $0.kind == .truncated })
    }
}
