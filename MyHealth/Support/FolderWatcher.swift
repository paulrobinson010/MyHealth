import Foundation
import HealthCore

/// Watches a directory and fires when its contents change.
///
/// Used for the iCloud Drive folder your iPhone drops `export.zip` into, so a
/// fresh export shows up in the app without anyone opening a file panel.
/// Changes are coalesced — iCloud writes a file in bursts, and one import per
/// burst is the point.
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private let url: URL
    private let onChange: () -> Void
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.myhealth.folder-watcher")

    init?(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange

        let accessing = url.startAccessingSecurityScopedResource()
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            return nil
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue)
        source.setEventHandler { [weak self] in self?.scheduleCallback() }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        source.resume()
        self.source = source
    }

    private func scheduleCallback() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        // iCloud takes a while to finish materialising a multi-gigabyte zip.
        queue.asyncAfter(deadline: .now() + 5, execute: work)
    }

    deinit {
        debounce?.cancel()
        source?.cancel()
    }
}
