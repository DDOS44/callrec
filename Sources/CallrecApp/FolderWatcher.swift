import Foundation

/// Watches ~/CallRecordings (and the day folders inside it) so new calls show
/// up while a dial session is running.
final class FolderWatcher {
    private var streams: [DispatchSourceFileSystemObject] = []
    private var descriptors: [Int32] = []
    private let onChange: () -> Void
    private let url: URL
    private var rescan: Timer?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        watchAll()
        // Day folders come and go, so re-attach watchers periodically.
        rescan = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.watchAll()
        }
    }

    private func watchAll() {
        stop()
        var targets = [url]
        let days = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0.count == 10 }
            .sorted(by: >)
            .prefix(3)
        targets += days.map { url.appendingPathComponent($0) }
        targets.forEach(watch)
    }

    private func watch(_ target: URL) {
        let fd = open(target.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.onChange() }
        source.setCancelHandler { close(fd) }
        source.resume()
        streams.append(source)
        descriptors.append(fd)
    }

    private func stop() {
        streams.forEach { $0.cancel() }
        streams.removeAll()
        descriptors.removeAll()
    }

    deinit { stop() }
}
