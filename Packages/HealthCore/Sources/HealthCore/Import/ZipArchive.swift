import Foundation
#if canImport(Compression)
import Compression
#endif

/// A read-only ZIP reader good enough for what Health produces: a handful of
/// stored or deflated entries, one of which is the several-gigabyte
/// `export.xml`.
///
/// Written by hand rather than shelling out to `unzip`/`ditto` so the app stays
/// inside its sandbox and can stream the entry straight to a temporary file
/// instead of materialising it in memory.
public struct ZipArchive {

    public struct Entry: Sendable {
        public let path: String
        public let compressedSize: Int
        public let uncompressedSize: Int
        let compressionMethod: UInt16
        let localHeaderOffset: Int

        public var fileName: String {
            path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    public enum ZipError: LocalizedError {
        case notAZipArchive
        case unsupportedCompression(UInt16)
        case corrupt(String)

        public var errorDescription: String? {
            switch self {
            case .notAZipArchive:
                return "The file is not a readable ZIP archive."
            case .unsupportedCompression(let method):
                return "The archive uses an unsupported compression method (\(method))."
            case .corrupt(let detail):
                return "The archive appears to be damaged: \(detail)"
            }
        }
    }

    public let url: URL
    public let entries: [Entry]

    public init(url: URL) throws {
        self.url = url
        self.entries = try ZipArchive.readCentralDirectory(at: url)
    }

    /// The entry most likely to be the Health export XML.
    public func healthExportEntry() -> Entry? {
        entries.first { $0.fileName == "export.xml" }
            ?? entries.first { $0.path.lowercased().hasSuffix("export.xml") }
            ?? entries.first { $0.path.lowercased().hasSuffix(".xml") && !$0.path.contains("__MACOSX") }
    }

    // MARK: - Central directory

    private static func readCentralDirectory(at url: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = Int((try handle.seekToEnd()))
        guard size > 22 else { throw ZipError.notAZipArchive }

        // The end-of-central-directory record lives in the last 64KB.
        let tailLength = min(size, 65_557)
        try handle.seek(toOffset: UInt64(size - tailLength))
        guard let tail = try handle.read(upToCount: tailLength), tail.count == tailLength else {
            throw ZipError.notAZipArchive
        }
        let bytes = [UInt8](tail)

        var endOffset: Int?
        var index = bytes.count - 22
        while index >= 0 {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B,
               bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                endOffset = index
                break
            }
            index -= 1
        }
        guard let end = endOffset else { throw ZipError.notAZipArchive }

        var entryCount = Int(read16(bytes, end + 10))
        var directorySize = Int(read32(bytes, end + 12))
        var directoryOffset = Int(read32(bytes, end + 16))

        // ZIP64 — Health exports pass 4GB more often than you would think.
        if directoryOffset == 0xFFFF_FFFF || directorySize == 0xFFFF_FFFF || entryCount == 0xFFFF {
            let (count, dirSize, dirOffset) = try readZip64Locator(handle: handle,
                                                                   tail: bytes,
                                                                   endOffset: end)
            entryCount = count
            directorySize = dirSize
            directoryOffset = dirOffset
        }

        guard directoryOffset >= 0, directorySize > 0, directoryOffset + directorySize <= size else {
            throw ZipError.corrupt("central directory out of bounds")
        }

        try handle.seek(toOffset: UInt64(directoryOffset))
        guard let directoryData = try handle.read(upToCount: directorySize),
              directoryData.count == directorySize else {
            throw ZipError.corrupt("central directory truncated")
        }
        let directory = [UInt8](directoryData)

        var entries: [Entry] = []
        var cursor = 0
        for _ in 0..<entryCount {
            guard cursor + 46 <= directory.count else { break }
            guard directory[cursor] == 0x50, directory[cursor + 1] == 0x4B,
                  directory[cursor + 2] == 0x01, directory[cursor + 3] == 0x02 else { break }

            let method = read16(directory, cursor + 10)
            var compressed = Int(read32(directory, cursor + 20))
            var uncompressed = Int(read32(directory, cursor + 24))
            let nameLength = Int(read16(directory, cursor + 28))
            let extraLength = Int(read16(directory, cursor + 30))
            let commentLength = Int(read16(directory, cursor + 32))
            var localOffset = Int(read32(directory, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= directory.count else { break }
            let name = String(decoding: directory[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            // ZIP64 extended information overrides the 32-bit fields.
            let extraStart = nameStart + nameLength
            if extraLength > 0, extraStart + extraLength <= directory.count {
                var extraCursor = extraStart
                while extraCursor + 4 <= extraStart + extraLength {
                    let headerID = read16(directory, extraCursor)
                    let dataSize = Int(read16(directory, extraCursor + 2))
                    var field = extraCursor + 4
                    if headerID == 0x0001 {
                        if uncompressed == 0xFFFF_FFFF, field + 8 <= directory.count {
                            uncompressed = Int(read64(directory, field)); field += 8
                        }
                        if compressed == 0xFFFF_FFFF, field + 8 <= directory.count {
                            compressed = Int(read64(directory, field)); field += 8
                        }
                        if localOffset == 0xFFFF_FFFF, field + 8 <= directory.count {
                            localOffset = Int(read64(directory, field))
                        }
                    }
                    extraCursor += 4 + dataSize
                }
            }

            if !name.hasSuffix("/") {
                entries.append(Entry(path: name,
                                     compressedSize: compressed,
                                     uncompressedSize: uncompressed,
                                     compressionMethod: method,
                                     localHeaderOffset: localOffset))
            }
            cursor = extraStart + extraLength + commentLength
        }

        guard !entries.isEmpty else { throw ZipError.corrupt("no files in archive") }
        return entries
    }

    private static func readZip64Locator(handle: FileHandle,
                                         tail: [UInt8],
                                         endOffset: Int) throws -> (Int, Int, Int) {
        // Locator sits immediately before the end-of-central-directory record.
        let locatorOffset = endOffset - 20
        guard locatorOffset >= 0,
              tail[locatorOffset] == 0x50, tail[locatorOffset + 1] == 0x4B,
              tail[locatorOffset + 2] == 0x06, tail[locatorOffset + 3] == 0x07 else {
            throw ZipError.corrupt("missing ZIP64 locator")
        }
        let zip64End = Int(read64(tail, locatorOffset + 8))
        try handle.seek(toOffset: UInt64(zip64End))
        guard let data = try handle.read(upToCount: 56), data.count == 56 else {
            throw ZipError.corrupt("truncated ZIP64 directory record")
        }
        let record = [UInt8](data)
        guard record[0] == 0x50, record[1] == 0x4B, record[2] == 0x06, record[3] == 0x06 else {
            throw ZipError.corrupt("bad ZIP64 directory record")
        }
        return (Int(read64(record, 32)), Int(read64(record, 40)), Int(read64(record, 48)))
    }

    // MARK: - Extraction

    /// Streams one entry to `destination`, reporting 0...1 progress.
    /// Returns the number of bytes written.
    @discardableResult
    public func extract(_ entry: Entry,
                        to destination: URL,
                        progress: ((Double) -> Void)? = nil,
                        isCancelled: (() -> Bool)? = nil) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // The local header repeats the name and extra-field lengths, which are
        // the only reliable way to find where the entry's bytes actually start.
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        guard let headerData = try handle.read(upToCount: 30), headerData.count == 30 else {
            throw ZipError.corrupt("truncated local header")
        }
        let header = [UInt8](headerData)
        guard header[0] == 0x50, header[1] == 0x4B, header[2] == 0x03, header[3] == 0x04 else {
            throw ZipError.corrupt("bad local header signature")
        }
        let nameLength = Int(ZipArchive.read16(header, 26))
        let extraLength = Int(ZipArchive.read16(header, 28))
        let dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        try handle.seek(toOffset: UInt64(dataStart))

        switch entry.compressionMethod {
        case 0:
            return try copyStored(from: handle, to: output, length: entry.compressedSize,
                                  progress: progress, isCancelled: isCancelled)
        case 8:
            #if canImport(Compression)
            return try inflate(from: handle, to: output, entry: entry,
                               progress: progress, isCancelled: isCancelled)
            #else
            throw ZipError.unsupportedCompression(entry.compressionMethod)
            #endif
        default:
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }
    }

    private func copyStored(from input: FileHandle,
                            to output: FileHandle,
                            length: Int,
                            progress: ((Double) -> Void)?,
                            isCancelled: (() -> Bool)?) throws -> Int {
        let chunkSize = 4 * 1024 * 1024
        var remaining = length
        var written = 0
        while remaining > 0 {
            if isCancelled?() == true { throw ImportError.cancelled }
            let toRead = min(chunkSize, remaining)
            guard let chunk = try input.read(upToCount: toRead), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            written += chunk.count
            remaining -= chunk.count
            progress?(Double(written) / Double(max(1, length)))
        }
        return written
    }

    #if canImport(Compression)
    /// Raw DEFLATE, which is what ZIP stores — `COMPRESSION_ZLIB` in Apple's
    /// compression framework is the headerless variant, so it matches directly.
    ///
    /// Input is copied into a buffer this function owns for its whole lifetime,
    /// because `compression_stream` keeps `src_ptr` live across calls and a
    /// pointer borrowed from a `Data` would not survive the next iteration.
    private func inflate(from input: FileHandle,
                         to output: FileHandle,
                         entry: Entry,
                         progress: ((Double) -> Void)?,
                         isCancelled: (() -> Bool)?) throws -> Int {
        let inputCapacity = 1 << 20
        let outputCapacity = 4 << 20

        let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCapacity)
        defer { inputBuffer.deallocate() }
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)
        defer { outputBuffer.deallocate() }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                != COMPRESSION_STATUS_ERROR else {
            throw ZipError.corrupt("could not start decompression")
        }
        defer { compression_stream_destroy(stream) }

        stream.pointee.src_ptr = UnsafePointer(inputBuffer)
        stream.pointee.src_size = 0
        stream.pointee.dst_ptr = outputBuffer
        stream.pointee.dst_size = outputCapacity

        var compressedRemaining = entry.compressedSize
        var totalWritten = 0
        var flags: Int32 = 0

        while true {
            if isCancelled?() == true { throw ImportError.cancelled }

            if stream.pointee.src_size == 0 && flags == 0 {
                let toRead = min(inputCapacity, compressedRemaining)
                let chunk = toRead > 0 ? ((try input.read(upToCount: toRead)) ?? Data()) : Data()
                if chunk.isEmpty {
                    compressedRemaining = 0
                    flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                } else {
                    chunk.copyBytes(to: inputBuffer, count: chunk.count)
                    stream.pointee.src_ptr = UnsafePointer(inputBuffer)
                    stream.pointee.src_size = chunk.count
                    compressedRemaining -= chunk.count
                    if compressedRemaining <= 0 {
                        flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    }
                }
            }

            let status = compression_stream_process(stream, flags)

            let produced = outputCapacity - stream.pointee.dst_size
            if produced > 0 {
                try output.write(contentsOf: Data(bytes: outputBuffer, count: produced))
                totalWritten += produced
                stream.pointee.dst_ptr = outputBuffer
                stream.pointee.dst_size = outputCapacity
                if entry.uncompressedSize > 0 {
                    progress?(Double(totalWritten) / Double(entry.uncompressedSize))
                }
            }

            if status == COMPRESSION_STATUS_END { break }
            if status == COMPRESSION_STATUS_ERROR { throw ZipError.corrupt("decompression failed") }
        }

        return totalWritten
    }
    #endif

    // MARK: - Little-endian readers

    static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        var value: UInt32 = 0
        for i in (0..<4).reversed() { value = (value << 8) | UInt32(bytes[offset + i]) }
        return value
    }

    static func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        guard offset + 7 < bytes.count else { return 0 }
        var value: UInt64 = 0
        for i in (0..<8).reversed() { value = (value << 8) | UInt64(bytes[offset + i]) }
        return value
    }
}
