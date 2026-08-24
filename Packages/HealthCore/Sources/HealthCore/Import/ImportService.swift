import Foundation

/// Turns a file the user picked — `export.zip`, a loose `export.xml`, or the
/// folder Health unzips to — into a `HealthDatabase`.
public struct ImportService {

    public init() {}

    /// Resolves whatever the user handed us to an `export.xml` on disk,
    /// unzipping into a temporary directory when needed.
    /// The caller is responsible for deleting `temporaryDirectory` when done.
    public struct ResolvedSource {
        public let xmlURL: URL
        public let temporaryDirectory: URL?
        public let displayName: String
    }

    public func resolve(_ url: URL,
                        progress: (@Sendable (ImportProgress) -> Void)? = nil,
                        isCancelled: (@Sendable () -> Bool)? = nil) throws -> ResolvedSource {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ImportError.fileNotFound(url)
        }

        if isDirectory.boolValue {
            let candidates = [
                url.appendingPathComponent("export.xml"),
                url.appendingPathComponent("apple_health_export/export.xml")
            ]
            guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw ImportError.notAHealthExport
            }
            return ResolvedSource(xmlURL: found, temporaryDirectory: nil, displayName: url.lastPathComponent)
        }

        if url.pathExtension.lowercased() == "xml" {
            return ResolvedSource(xmlURL: url, temporaryDirectory: nil, displayName: url.lastPathComponent)
        }

        guard url.pathExtension.lowercased() == "zip" else { throw ImportError.notAHealthExport }

        progress?(ImportProgress(fraction: 0, message: "Opening \(url.lastPathComponent)…"))
        let archive = try ZipArchive(url: url)
        guard let entry = archive.healthExportEntry() else { throw ImportError.notAHealthExport }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyHealthImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let destination = temporaryDirectory.appendingPathComponent("export.xml")

        try archive.extract(entry, to: destination, progress: { fraction in
            progress?(ImportProgress(fraction: fraction * 0.35, message: "Unzipping export…"))
        }, isCancelled: { isCancelled?() ?? false })

        return ResolvedSource(xmlURL: destination,
                              temporaryDirectory: temporaryDirectory,
                              displayName: url.lastPathComponent)
    }

    /// Full pipeline: resolve, parse, clean up.
    public func importDatabase(from url: URL,
                               progress: (@Sendable (ImportProgress) -> Void)? = nil,
                               isCancelled: (@Sendable () -> Bool)? = nil) throws -> HealthDatabase {
        let needsScopedAccess = url.startAccessingSecurityScopedResource()
        defer { if needsScopedAccess { url.stopAccessingSecurityScopedResource() } }

        let source = try resolve(url, progress: progress, isCancelled: isCancelled)
        defer {
            if let temporary = source.temporaryDirectory {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        let unzipped = source.temporaryDirectory != nil
        let parser = HealthExportParser(fileURL: source.xmlURL, progress: { update in
            // Unzipping already claimed the first 35% of the bar.
            let scaled = unzipped ? 0.35 + update.fraction * 0.65 : update.fraction
            progress?(ImportProgress(fraction: scaled,
                                     message: update.message,
                                     recordsProcessed: update.recordsProcessed))
        }, isCancelled: isCancelled)

        var database = try parser.parse()
        database.sourceFileName = source.displayName
        return database
    }

    /// Combines a freshly imported export with what is already stored.
    ///
    /// Each export is a complete dump, but importing an older one should not
    /// erase newer days, so days are unioned and the newer export wins wherever
    /// both cover the same day.
    public func merge(existing: HealthDatabase, incoming: HealthDatabase) -> HealthDatabase {
        let incomingIsNewer = (incoming.exportedAt ?? incoming.importedAt)
            >= (existing.exportedAt ?? existing.importedAt)

        var byOrdinal: [Int: DailySummary] = [:]
        let (first, second) = incomingIsNewer ? (existing, incoming) : (incoming, existing)
        for summary in first.days { byOrdinal[summary.day.ordinal] = summary }
        for summary in second.days {
            if var current = byOrdinal[summary.day.ordinal] {
                // Keep values the winning export happens not to carry.
                for (metric, value) in summary.values { current.values[metric] = value }
                byOrdinal[summary.day.ordinal] = current
            } else {
                byOrdinal[summary.day.ordinal] = summary
            }
        }

        var workoutsByID: [String: WorkoutSummary] = [:]
        for workout in first.workouts + second.workouts {
            workoutsByID[workout.id] = workout
        }

        var profile = second.profile
        if profile.dateOfBirth == nil { profile.dateOfBirth = first.profile.dateOfBirth }
        if profile.biologicalSex == .unknown { profile.biologicalSex = first.profile.biologicalSex }

        var merged = HealthDatabase(profile: profile,
                                    days: Array(byOrdinal.values),
                                    workouts: Array(workoutsByID.values),
                                    exportedAt: second.exportedAt ?? first.exportedAt,
                                    sourceFileName: second.sourceFileName ?? first.sourceFileName)
        merged.importedAt = Date()
        return merged
    }
}
