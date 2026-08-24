import XCTest
@testable import HealthCore

final class ZipArchiveTests: XCTestCase {

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    /// Builds a minimal ZIP with stored (uncompressed) entries. Enough to
    /// exercise end-of-central-directory discovery, the central directory walk
    /// and local-header offset resolution, which is where a hand-rolled reader
    /// goes wrong.
    private func makeStoredZip(entries: [(name: String, contents: String)]) -> Data {
        var output = Data()
        var directory = Data()

        func append16(_ data: inout Data, _ value: UInt16) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }
        func append32(_ data: inout Data, _ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) {
                data.append(UInt8((value >> UInt32(shift)) & 0xFF))
            }
        }

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let payload = Data(entry.contents.utf8)
            let localOffset = UInt32(output.count)

            output.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            append16(&output, 20)                      // version needed
            append16(&output, 0)                       // flags
            append16(&output, 0)                       // method: stored
            append16(&output, 0)                       // mod time
            append16(&output, 0)                       // mod date
            append32(&output, 0)                       // crc32 (not verified by the reader)
            append32(&output, UInt32(payload.count))   // compressed size
            append32(&output, UInt32(payload.count))   // uncompressed size
            append16(&output, UInt16(nameBytes.count))
            append16(&output, 0)                       // extra length
            output.append(nameBytes)
            output.append(payload)

            directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            append16(&directory, 20)                   // version made by
            append16(&directory, 20)                   // version needed
            append16(&directory, 0)                    // flags
            append16(&directory, 0)                    // method
            append16(&directory, 0)
            append16(&directory, 0)
            append32(&directory, 0)                    // crc32
            append32(&directory, UInt32(payload.count))
            append32(&directory, UInt32(payload.count))
            append16(&directory, UInt16(nameBytes.count))
            append16(&directory, 0)                    // extra length
            append16(&directory, 0)                    // comment length
            append16(&directory, 0)                    // disk number
            append16(&directory, 0)                    // internal attributes
            append32(&directory, 0)                    // external attributes
            append32(&directory, localOffset)
            directory.append(nameBytes)
        }

        let directoryOffset = UInt32(output.count)
        output.append(directory)
        output.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        append16(&output, 0)                           // disk number
        append16(&output, 0)                           // disk with central directory
        append16(&output, UInt16(entries.count))
        append16(&output, UInt16(entries.count))
        append32(&output, UInt32(directory.count))
        append32(&output, directoryOffset)
        append16(&output, 0)                           // comment length
        return output
    }

    func testReadsCentralDirectory() throws {
        let url = temporaryDirectory.appendingPathComponent("test.zip")
        try makeStoredZip(entries: [
            ("apple_health_export/export_cda.xml", "<ClinicalDocument/>"),
            ("apple_health_export/export.xml", "<HealthData/>")
        ]).write(to: url)

        let archive = try ZipArchive(url: url)
        XCTAssertEqual(archive.entries.count, 2)
        XCTAssertEqual(archive.healthExportEntry()?.path, "apple_health_export/export.xml")
    }

    func testExtractsStoredEntryByteForByte() throws {
        let payload = String(repeating: "<Record value=\"1\"/>\n", count: 500)
        let url = temporaryDirectory.appendingPathComponent("test.zip")
        try makeStoredZip(entries: [("noise.txt", "ignore me"),
                                    ("apple_health_export/export.xml", payload)]).write(to: url)

        let archive = try ZipArchive(url: url)
        let entry = try XCTUnwrap(archive.healthExportEntry())
        let destination = temporaryDirectory.appendingPathComponent("out.xml")
        let written = try archive.extract(entry, to: destination)

        XCTAssertEqual(written, payload.utf8.count)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), payload)
    }

    func testRejectsNonZipFiles() throws {
        let url = temporaryDirectory.appendingPathComponent("not.zip")
        try Data("this is definitely not a zip archive, it is just some text".utf8).write(to: url)
        XCTAssertThrowsError(try ZipArchive(url: url))
    }
}

final class HealthStoreTests: XCTestCase {

    func testDatabaseSurvivesARoundTripThroughDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HealthStore(fileURL: directory.appendingPathComponent("db.plist"))
        XCTAssertNil(try store.load())

        let original = SampleData.database(years: 1, endingAt: DayKey(year: 2024, month: 6, day: 1))
        try store.save(original)

        // Saving twice must also work — the second write replaces the first.
        try store.save(original)

        let reloaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(reloaded.days.count, original.days.count)
        XCTAssertEqual(reloaded.workouts.count, original.workouts.count)
        XCTAssertEqual(reloaded.profile.dateOfBirth, original.profile.dateOfBirth)
        XCTAssertEqual(reloaded.days.first?.values[.steps], original.days.first?.values[.steps])

        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testMergeKeepsTheNewerExportsValuesAndUnionsDays() throws {
        let day = DayKey(year: 2024, month: 5, day: 1)
        var older = HealthDatabase(days: [
            DailySummary(day: day, values: [.steps: 1_000, .sleepHours: 7]),
            DailySummary(day: day.adding(days: -1), values: [.steps: 900])
        ])
        older.exportedAt = Date(timeIntervalSince1970: 1_700_000_000)

        var newer = HealthDatabase(days: [
            DailySummary(day: day, values: [.steps: 1_500]),
            DailySummary(day: day.adding(days: 1), values: [.steps: 2_000])
        ])
        newer.exportedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let merged = ImportService().merge(existing: older, incoming: newer)
        XCTAssertEqual(merged.days.count, 3)

        let overlapping = try XCTUnwrap(merged.days.first { $0.day == day })
        XCTAssertEqual(overlapping[.steps], 1_500)   // newer export wins
        XCTAssertEqual(overlapping[.sleepHours], 7)  // but nothing is lost
    }

    func testAvailableMetricsIgnoresSparseOnes() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        var days: [DailySummary] = []
        for offset in 0..<20 {
            var values: [Metric: Double] = [.steps: 8_000]
            if offset == 0 { values[.vo2Max] = 44 }
            days.append(DailySummary(day: start.adding(days: offset), values: values))
        }
        let available = HealthDatabase(days: days).availableMetrics(minimumDays: 5)
        XCTAssertTrue(available.contains(.steps))
        XCTAssertFalse(available.contains(.vo2Max))
    }
}
