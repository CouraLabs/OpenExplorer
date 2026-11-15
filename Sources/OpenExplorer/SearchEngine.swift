import Foundation

enum SearchMode: String, CaseIterable, Identifiable {
    case name, contents
    var id: Self { self }
    var title: String { self == .name ? "Name" : "Contents" }
}

struct SearchOptions: Equatable {
    var mode: SearchMode = .name
    /// Name mode: glob(s) such as `*.swift; report*`. Contents mode: the text or regex to grep for.
    var query = ""
    /// Contents mode only: restrict grep to files whose name matches these globs.
    var fileGlobs = ""
    var recursive = true
    var caseSensitive = false
    var regex = false
    var showHidden = false
}

/// Thread-safe cancellation flag shared with the background search.
final class SearchToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock {
            cancelled = true
            if process?.isRunning == true { process?.terminate() }
        }
    }

    /// Registers a running grep so cancel() can stop it. Returns false if already cancelled.
    func attach(_ process: Process) -> Bool {
        lock.withLock {
            if cancelled { return false }
            self.process = process
            return true
        }
    }
}

/// Runs name (glob) and contents (grep) searches off the main thread, streaming results in batches.
enum SearchEngine {
    static let resultLimit = 5000

    /// Splits "*.swift; *.md, notes" into globs. Plain words become "*word*" (substring match, like Windows search).
    static func globs(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.contains(where: { "*?[".contains($0) }) ? $0 : "*\($0)*" }
    }

    static func matches(_ globs: [String], name: String, relativePath: String, caseSensitive: Bool) -> Bool {
        let flags = caseSensitive ? 0 : FNM_CASEFOLD
        return globs.contains { glob in
            // Globs containing "/" match the path relative to the search folder, e.g. "src/*.swift".
            let subject = glob.contains("/") ? relativePath : name
            return fnmatch(glob, subject, flags) == 0
        }
    }

    /// Runs the search. `deliver` is called on the main queue with batches of results; `finish` once at the end.
    static func run(
        in root: URL,
        options: SearchOptions,
        token: SearchToken,
        deliver: @escaping @Sendable ([FileItem]) -> Void,
        finish: @escaping @Sendable (_ truncated: Bool, _ error: String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let batcher = Batcher(deliver: deliver)
            var error: String?
            switch options.mode {
            case .name:
                nameSearch(root: root, options: options, token: token, batcher: batcher)
            case .contents:
                error = contentSearch(root: root, options: options, token: token, batcher: batcher)
            }
            batcher.flush()
            let truncated = batcher.count >= resultLimit
            if !token.isCancelled {
                DispatchQueue.main.async { finish(truncated, error) }
            }
        }
    }

    // MARK: Name (glob)

    private static func nameSearch(root: URL, options: SearchOptions, token: SearchToken, batcher: Batcher) {
        let globs = globs(from: options.query)
        guard !globs.isEmpty else { return }
        for url in enumerate(root: root, options: options) {
            if token.isCancelled || batcher.count >= resultLimit { return }
            let relative = relativePath(of: url, in: root)
            guard matches(globs, name: url.lastPathComponent, relativePath: relative, caseSensitive: options.caseSensitive),
                  var item = FileSystem.makeItem(url) else { continue }
            item.location = parentPath(of: relative)
            batcher.add(item, token: token)
        }
    }

    private static func enumerate(root: URL, options: SearchOptions) -> AnySequence<URL> {
        var enumOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !options.showHidden { enumOptions.insert(.skipsHiddenFiles) }
        if !options.recursive { enumOptions.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: FileSystem.resourceKeys, options: enumOptions,
            errorHandler: { _, _ in true }  // skip unreadable folders, keep going
        ) else { return AnySequence([]) }
        return AnySequence(enumerator.lazy.compactMap { $0 as? URL })
    }

    // MARK: Contents (grep)

    private static func contentSearch(root: URL, options: SearchOptions, token: SearchToken, batcher: Batcher) -> String? {
        guard !options.query.isEmpty else { return nil }
        let fileGlobs = globs(from: options.fileGlobs)

        var args = ["-I", "-H", "-n", "-m", "1", "--null", "-s", "-d", "skip", options.regex ? "-E" : "-F"]
        if !options.caseSensitive { args.append("-i") }
        args += ["-e", options.query, "--"]

        // Walk the folder ourselves (skipping hidden items and app bundles like Finder), then hand grep
        // the matching files in chunks to stay under ARG_MAX.
        var chunk: [String] = []
        var lastError: String?
        func runChunk() {
            guard !chunk.isEmpty else { return }
            lastError = runGrep(args + chunk, root: root, options: options, token: token, batcher: batcher) ?? lastError
            chunk.removeAll(keepingCapacity: true)
        }
        for url in enumerate(root: root, options: options) {
            if token.isCancelled || batcher.count >= resultLimit { return lastError }
            guard !FileSystem.isFolder(url) else { continue }
            if !fileGlobs.isEmpty,
               !matches(fileGlobs, name: url.lastPathComponent, relativePath: relativePath(of: url, in: root),
                        caseSensitive: options.caseSensitive) { continue }
            chunk.append(url.path)
            if chunk.count >= 500 { runChunk() }
        }
        runChunk()
        return lastError
    }

    /// Runs grep, streaming "path\0line:text" records into the batcher. Returns an error message if grep failed.
    private static func runGrep(_ args: [String], root: URL, options: SearchOptions,
                                token: SearchToken, batcher: Batcher) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = args
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return "Couldn’t run grep: \(error.localizedDescription)" }
        guard token.attach(process) else {
            process.terminate()
            return nil
        }

        var buffer = Data()
        let reader = stdout.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                handleGrepLine(Data(line), root: root, token: token, batcher: batcher)
            }
            if token.isCancelled || batcher.count >= resultLimit {
                process.terminate()
                break
            }
        }
        process.waitUntilExit()
        // Exit status 1 just means "no matches"; 2 means a real error (e.g. an invalid regex).
        if process.terminationStatus == 2 && batcher.count == 0 && !token.isCancelled {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !message.isEmpty { return message }
        }
        return nil
    }

    private static func handleGrepLine(_ line: Data, root: URL, token: SearchToken, batcher: Batcher) {
        guard let nul = line.firstIndex(of: 0),
              let path = String(data: line[line.startIndex..<nul], encoding: .utf8) else { return }
        let rest = String(decoding: line[line.index(after: nul)...], as: UTF8.self)
        let url = URL(fileURLWithPath: path)
        let relative = relativePath(of: url, in: root)
        guard var item = FileSystem.makeItem(url) else { return }
        item.location = parentPath(of: relative)
        if let colon = rest.firstIndex(of: ":") {
            let lineNumber = rest[rest.startIndex..<colon]
            let text = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            item.match = "\(lineNumber): \(text.prefix(300))"
        }
        batcher.add(item, token: token)
    }

    // MARK: Helpers

    private static func relativePath(of url: URL, in root: URL) -> String {
        let rootPath = root.path == "/" ? "/" : root.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }

    private static func parentPath(of relative: String) -> String {
        (relative as NSString).deletingLastPathComponent
    }

    /// Collects results and hands them to the main queue in batches (keeps the UI responsive).
    private final class Batcher: @unchecked Sendable {
        private let deliver: @Sendable ([FileItem]) -> Void
        private var pending: [FileItem] = []
        private var lastFlush = Date()
        private(set) var count = 0

        init(deliver: @escaping @Sendable ([FileItem]) -> Void) { self.deliver = deliver }

        func add(_ item: FileItem, token: SearchToken) {
            guard count < SearchEngine.resultLimit else { return }
            pending.append(item)
            count += 1
            if pending.count >= 200 || Date().timeIntervalSince(lastFlush) > 0.25 {
                flush(token: token)
            }
        }

        func flush(token: SearchToken? = nil) {
            guard !pending.isEmpty, token?.isCancelled != true else { return }
            let batch = pending
            pending = []
            lastFlush = Date()
            let deliver = self.deliver
            DispatchQueue.main.async { deliver(batch) }
        }
    }
}
