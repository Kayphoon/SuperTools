import AppKit
import CryptoKit
import Foundation

/// Numeric dotted-version comparison ("1.10.0" > "1.9.0"). A leading "v" is
/// ignored and missing components count as zero.
enum VersionCompare {
    static func normalized(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        normalized(version).split(separator: ".").map { Int($0) ?? 0 }
    }
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(String)    // newer version found, not downloaded yet
    case downloading(String)
    case ready(String)        // downloaded and verified, waiting for the user
    case installing
    case failed(String)
}

enum UpdateError: LocalizedError {
    case missingAssets
    case checksumMismatch
    case invalidBundle
    case signatureInvalid
    case identityChanged
    case notWritable(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAssets: return "最新版本缺少安装包或校验文件。"
        case .checksumMismatch: return "下载的安装包校验不通过，已丢弃。"
        case .invalidBundle: return "下载的安装包内容不完整，已丢弃。"
        case .signatureInvalid: return "下载的应用签名验证失败，已丢弃。"
        case .identityChanged: return "下载的应用签名与当前应用不一致，已丢弃。"
        case .notWritable(let path): return "无法写入 \(path)，请把 SuperTools 移到个人应用文件夹后重试，或手动下载新版替换。"
        case .processFailed(let tool): return "\(tool) 执行失败。"
        }
    }
}

/// The update pipeline the settings page promises: check GitHub Releases on
/// launch and once a day, download a newer release in the background, verify
/// it (release sha256, bundle identity, code signature, signing-identity
/// continuity), stage it under the caches directory — and stop there.
/// Installing is a separate explicit step (`installReady`) that only runs
/// after the user confirms; nothing here ever replaces the app on its own.
@MainActor
final class Updater {
    private(set) var state: UpdateState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((UpdateState) -> Void)?
    /// Fired once per version when a verified update is staged and the user
    /// should be asked whether to install it.
    var onReadyToInstall: ((String) -> Void)?
    /// User-initiated checks report their quiet outcomes; automatic ones don't.
    var onUpToDate: (() -> Void)?
    var onCheckFailed: ((String) -> Void)?

    private static let repository = "Kayphoon/SuperTools"
    private static let zipName = "SuperTools-macos-arm64.zip"
    private static let bundleIdentifier = "com.supertools.app"

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct PendingRelease {
        let version: String
        let zipURL: String
        let checksumURL: String
    }

    private struct StagingMarker: Codable {
        let version: String
    }

    private let session: URLSession
    private let stagingRoot: URL
    private let currentVersion: String
    private var autoCheck = true
    private var autoDownload = true
    private var pending: PendingRelease?
    private var timer: Timer?
    private var work: Task<Void, Never>?
    private var promptedVersion: String?

    init(currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
         stagingRoot: URL? = nil,
         session: URLSession = .shared) {
        self.currentVersion = VersionCompare.normalized(currentVersion)
        self.session = session
        if let stagingRoot {
            self.stagingRoot = stagingRoot
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.stagingRoot = caches.appendingPathComponent("com.supertools.app/updates", isDirectory: true)
        }
    }

    // MARK: - Lifecycle

    func start(autoCheck: Bool, autoDownload: Bool) {
        self.autoCheck = autoCheck
        self.autoDownload = autoDownload
        restoreStagedUpdate()
        scheduleTimerIfNeeded()
        if autoCheck {
            work = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.checkNow(userInitiated: false)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        work?.cancel()
        work = nil
    }

    func preferencesChanged(check: Bool, download: Bool) {
        let wasChecking = autoCheck
        autoCheck = check
        autoDownload = download
        scheduleTimerIfNeeded()
        if check, !wasChecking, case .idle = state {
            checkNow(userInitiated: false)
        }
    }

    private func scheduleTimerIfNeeded() {
        timer?.invalidate()
        timer = nil
        guard autoCheck else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkNow(userInitiated: false) }
        }
    }

    // MARK: - Check

    func checkNow(userInitiated: Bool) {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            await self.runCheck(userInitiated: userInitiated)
        }
    }

    private func runCheck(userInitiated: Bool) async {
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            let remote = VersionCompare.normalized(release.tagName)
            guard VersionCompare.isNewer(remote, than: currentVersion) else {
                clearStaging()
                state = .upToDate
                if userInitiated { onUpToDate?() }
                return
            }
            if let staged = stagedVersion(), staged == remote, stagedAppURL(version: remote) != nil {
                state = .ready(remote)
                promptIfNeeded(for: remote)
                return
            }
            guard let zip = release.assets.first(where: { $0.name == Self.zipName }),
                  let checksum = release.assets.first(where: { $0.name == Self.zipName + ".sha256" }) else {
                throw UpdateError.missingAssets
            }
            pending = PendingRelease(version: remote,
                                     zipURL: zip.browserDownloadURL,
                                     checksumURL: checksum.browserDownloadURL)
            if autoDownload {
                await downloadAndStage()
            } else {
                state = .available(remote)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
            if userInitiated { onCheckFailed?(message) }
        }
    }

    func downloadNow() {
        guard case .available = state, pending != nil else { return }
        work?.cancel()
        work = Task { [weak self] in await self?.downloadAndStage() }
    }

    // MARK: - Download & verify

    private func downloadAndStage() async {
        guard let pending else { return }
        state = .downloading(pending.version)
        do {
            let fileManager = FileManager.default
            let directory = stagingRoot.appendingPathComponent(pending.version, isDirectory: true)
            try? fileManager.removeItem(at: directory)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let zipFile = directory.appendingPathComponent(Self.zipName)
            try await download(pending.zipURL, to: zipFile)
            let expected = try await fetchChecksum(pending.checksumURL)
            let actual = try sha256(of: zipFile)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw UpdateError.checksumMismatch
            }

            let extractDirectory = directory.appendingPathComponent("extracted", isDirectory: true)
            try fileManager.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
            guard runProcess("/usr/bin/ditto", ["-x", "-k", zipFile.path, extractDirectory.path]).status == 0 else {
                throw UpdateError.processFailed("解压")
            }
            let app = extractDirectory.appendingPathComponent("SuperTools.app")
            try verifyApp(app, version: pending.version)

            let marker = try JSONEncoder().encode(StagingMarker(version: pending.version))
            try marker.write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
            pruneOtherVersions(keeping: pending.version)
            state = .ready(pending.version)
            promptIfNeeded(for: pending.version)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
        }
    }

    private func verifyApp(_ app: URL, version: String) throws {
        guard let bundle = Bundle(path: app.path),
              bundle.bundleIdentifier == Self.bundleIdentifier,
              VersionCompare.normalized(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") == version else {
            throw UpdateError.invalidBundle
        }
        let verify = runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else { throw UpdateError.signatureInvalid }
        // Continuity: when the running app carries a real (non ad-hoc) signing
        // identity, the update must carry the same one, so a swapped or
        // re-signed build never reaches the install step.
        if let current = signingAuthority(of: Bundle.main.bundlePath),
           let next = signingAuthority(of: app.path),
           current != next {
            throw UpdateError.identityChanged
        }
    }

    /// The first `Authority=` line of a code signature, or nil for ad-hoc
    /// signatures, which have no authority to compare.
    private func signingAuthority(of path: String) -> String? {
        let result = runProcess("/usr/bin/codesign", ["-dv", "--verbose=2", path])
        guard !result.output.contains("Signature=adhoc") else { return nil }
        return result.output.split(separator: "\n").first { $0.hasPrefix("Authority=") }.map(String.init)
    }

    // MARK: - Install (explicit user confirmation only)

    func installReady() {
        guard case .ready(let version) = state, let stagedApp = stagedAppURL(version: version) else { return }
        let target = Bundle.main.bundleURL
        let fileManager = FileManager.default
        guard fileManager.isWritableFile(atPath: target.deletingLastPathComponent().path),
              fileManager.isWritableFile(atPath: target.path) else {
            let message = UpdateError.notWritable(target.path).errorDescription ?? ""
            state = .failed(message)
            onCheckFailed?(message)
            return
        }
        do {
            let script = stagingRoot.appendingPathComponent("install-\(version).sh")
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let body = """
            #!/bin/bash
            # Wait for the running app to exit, swap the bundle, relaunch.
            pid="$1"; src="$2"; dst="$3"
            while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.3; done
            backup="${dst}.update-backup"
            /bin/rm -rf "$backup"
            /bin/mv "$dst" "$backup" || exit 1
            if ! /usr/bin/ditto "$src" "$dst"; then /bin/mv "$backup" "$dst"; exit 1; fi
            /usr/bin/xattr -dr com.apple.quarantine "$dst" 2>/dev/null
            /usr/bin/open "$dst"
            /bin/sleep 3
            /bin/rm -rf "$backup"
            """
            try body.write(to: script, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path,
                                 String(ProcessInfo.processInfo.processIdentifier),
                                 stagedApp.path, target.path]
            state = .installing
            try process.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Staging bookkeeping

    private func stagedAppURL(version: String) -> URL? {
        let app = stagingRoot.appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("extracted/SuperTools.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
    }

    private func stagedVersion() -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path) else { return nil }
        return entries.filter { entry in
            let marker = stagingRoot.appendingPathComponent(entry).appendingPathComponent("ready.json")
            return FileManager.default.fileExists(atPath: marker.path)
        }.max { VersionCompare.isNewer($1, than: $0) }
    }

    /// A staged update from an earlier run survives restarts: if it is still
    /// newer than the running app, offer it again without re-downloading.
    private func restoreStagedUpdate() {
        guard let version = stagedVersion() else { return }
        guard VersionCompare.isNewer(version, than: currentVersion) else {
            clearStaging()
            return
        }
        if stagedAppURL(version: version) != nil {
            state = .ready(version)
            promptIfNeeded(for: version)
        }
    }

    private func pruneOtherVersions(keeping version: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path) else { return }
        for entry in entries where entry != version && !entry.hasPrefix("install-") {
            try? FileManager.default.removeItem(at: stagingRoot.appendingPathComponent(entry))
        }
    }

    private func clearStaging() {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path) else { return }
        for entry in entries where !entry.hasPrefix("install-") {
            try? FileManager.default.removeItem(at: stagingRoot.appendingPathComponent(entry))
        }
    }

    private func promptIfNeeded(for version: String) {
        guard promptedVersion != version else { return }
        promptedVersion = version
        onReadyToInstall?(version)
    }

    // MARK: - Network & process plumbing

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SuperTools-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.processFailed("检查更新")
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func fetchChecksum(_ urlString: String) async throws -> String {
        let (data, _) = try await session.data(from: URL(string: urlString)!)
        let text = String(decoding: data, as: UTF8.self)
        guard let hash = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first else {
            throw UpdateError.checksumMismatch
        }
        return String(hash)
    }

    private func download(_ urlString: String, to destination: URL) async throws {
        let (temporary, response) = try await session.download(from: URL(string: urlString)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.processFailed("下载更新")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func runProcess(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
