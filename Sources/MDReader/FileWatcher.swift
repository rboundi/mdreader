import Foundation

/// Watches a single file and calls `onChange` (on the main queue) when it is modified.
/// Handles editors that save atomically by replacing the file (delete/rename + recreate).
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start(attempt: 0)
    }

    /// False once the file has been missing long enough that watching stopped.
    var isWatching: Bool { source != nil || retrying }
    private var retrying = false

    deinit {
        pending?.cancel()
        source?.cancel()
    }

    private func start(attempt: Int) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // The file may be mid-replacement; retry a few times, then give up quietly.
            retrying = attempt < 10
            if retrying {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.start(attempt: attempt + 1)
                }
            }
            return
        }
        retrying = false
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if !src.data.isDisjoint(with: [.delete, .rename]) {
                src.cancel()
                self.source = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.start(attempt: 0)
                }
            }
            self.scheduleChange()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func scheduleChange() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }
}
