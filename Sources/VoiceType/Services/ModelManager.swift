import Foundation
import Combine

@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?

    /// Test-only override for the models directory. Never set outside XCTest
    /// targets — production always resolves to Application Support. Lets tests
    /// exercise deleteModel/downloadModel's filesystem logic without ever
    /// touching the owner's real downloaded models.
    var _testModelsDirectoryOverride: URL?

    private var modelsDirectory: URL {
        let modelsDir: URL
        if let override = _testModelsDirectoryOverride {
            modelsDir = override
        } else {
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let voiceTypeDirectory = applicationSupport.appendingPathComponent("VoiceType", isDirectory: true)
            modelsDir = voiceTypeDirectory.appendingPathComponent("Models", isDirectory: true)
        }

        if !FileManager.default.fileExists(atPath: modelsDir.path) {
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        }

        return modelsDir
    }

    private var currentDownloadingModel: TranscriptionModel?

    private init() {}

    func modelURL(for model: TranscriptionModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    func coreMLModelURL(for model: TranscriptionModel) -> URL {
        modelsDirectory.appendingPathComponent(model.coreMLFileName)
    }

    func coreMLZipURL(for model: TranscriptionModel) -> URL {
        modelsDirectory.appendingPathComponent(model.coreMLZipFileName)
    }

    func isModelDownloaded(model: TranscriptionModel) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(for: model).path)
    }

    func isCoreMLModelDownloaded(model: TranscriptionModel) -> Bool {
        isValidCoreMLBundle(at: coreMLModelURL(for: model))
    }

    /// Minimal structural check for a CoreML `.mlmodelc` bundle. The internal
    /// bundle format is a private Apple implementation detail that has already
    /// changed across macOS versions, so this deliberately checks only the
    /// handful of files present in every real bundle inspected on this machine
    /// (compiled program + metadata), not a full manifest — a stricter check
    /// would risk false negatives on a future OS. A trial `MLModel(contentsOf:)`
    /// load was considered and rejected: for large-v3-turbo it costs real
    /// seconds and memory on every install, and whisper.cpp already falls back
    /// to CPU if the encoder fails to load at runtime, so there's no safety
    /// case that justifies the cost.
    ///
    /// `nonisolated` (touches only the FileManager + a passed-in URL, no actor
    /// state) so it — and installCoreMLBundle below — can be called from the
    /// URLSession completion handler without a main-actor hop.
    nonisolated func isValidCoreMLBundle(at url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }

        for name in ["coremldata.bin", "model.mil"] {
            let path = url.appendingPathComponent(name).path
            guard let size = try? fm.attributesOfItem(atPath: path)[.size] as? Int64, size > 0 else {
                return false
            }
        }
        return true
    }

    /// Whether `model`'s CoreML encoder should be fetched: only for models that
    /// actually ship one (see `TranscriptionModel.hasCoreMLSupport` — e.g.
    /// small-q5_1 has none, and whisper.cpp strips the `-qX_X` suffix when
    /// looking up an encoder name we never build, so there is nothing to fetch
    /// for it on HuggingFace; downloading anyway pulls down a 404 HTML page
    /// that `unzip` then fails on) and isn't already installed.
    func needsCoreMLDownload(for model: TranscriptionModel) -> Bool {
        model.hasCoreMLSupport && !isCoreMLModelDownloaded(model: model)
    }

    /// `includeCoreML` is the caller's acceleration-policy verdict — whether
    /// the encoder should exist on disk at all for the current mode/hardware
    /// (see `AccelerationPolicyResolver.shouldInstallCoreML`). `ModelManager`
    /// itself never consults `AppSettings` or the capability probe: it only
    /// knows how to move files, and `needsCoreMLDownload` still gates on "does
    /// this model even ship an encoder, and is it missing" — both conditions
    /// must hold before a byte is fetched.
    func downloadModel(model: TranscriptionModel, includeCoreML: Bool) async throws {
        guard !isDownloading else {
            throw ModelError.alreadyDownloading
        }

        let needsMainModel = !isModelDownloaded(model: model)
        let needsCoreML = includeCoreML && needsCoreMLDownload(for: model)

        guard needsMainModel || needsCoreML else { return }

        currentDownloadingModel = model
        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        print("[ModelManager] Starting download: \(model.fileName)")

        if needsMainModel {
            try await downloadFile(url: URL(string: model.downloadURL)!, destination: modelURL(for: model))
        }

        if needsCoreML {
            print("[ModelManager] Downloading CoreML encoder for GPU acceleration...")
            try await downloadFile(url: URL(string: model.coreMLDownloadURL)!, destination: coreMLModelURL(for: model))
        }

        isDownloading = false
        currentDownloadingModel = nil
    }

    private func downloadFile(url: URL, destination: URL) async throws {
        print("[ModelManager] Downloading from \(url) to \(destination.path)")

        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                if let error {
                    print("[ModelManager] Download error: \(error)")
                    DispatchQueue.main.async {
                        self.downloadError = error.localizedDescription
                        self.isDownloading = false
                        self.currentDownloadingModel = nil
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let tempURL else {
                    DispatchQueue.main.async {
                        self.downloadError = "No download URL"
                        self.isDownloading = false
                        self.currentDownloadingModel = nil
                        continuation.resume(throwing: ModelError.downloadFailed)
                    }
                    return
                }

                // URLSession.downloadTask treats any completed transfer as "success" —
                // a 404 HTML page lands here just like a real file. Reject non-2xx
                // before anything touches disk, or unzip/moveItem fail later on
                // garbage input with a confusing error (this was the root cause of
                // the "Failed to unzip CoreML model" reports).
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    print("[ModelManager] Download rejected: HTTP \(httpResponse.statusCode) for \(url.lastPathComponent)")
                    DispatchQueue.main.async {
                        self.downloadError = "Server returned HTTP \(httpResponse.statusCode) for \(url.lastPathComponent)"
                        self.isDownloading = false
                        self.currentDownloadingModel = nil
                        continuation.resume(throwing: ModelError.httpError(statusCode: httpResponse.statusCode))
                    }
                    return
                }

                do {
                    if destination.pathExtension == "mlmodelc" {
                        try self.installCoreMLBundle(zipPath: tempURL, destination: destination)
                    } else {
                        let fm = FileManager.default
                        if fm.fileExists(atPath: destination.path) {
                            try fm.removeItem(at: destination)
                        }
                        try fm.moveItem(at: tempURL, to: destination)

                        guard fm.fileExists(atPath: destination.path) else {
                            throw ModelError.moveFailed
                        }

                        let size = try fm.attributesOfItem(atPath: destination.path)[.size] as? Int64 ?? 0
                        print("[ModelManager] Download completed: \(destination.lastPathComponent) (\(size / 1_000_000) MB)")
                    }

                    DispatchQueue.main.async {
                        self.downloadProgress = 1.0
                        continuation.resume()
                    }
                } catch {
                    print("[ModelManager] ERROR: \(error)")
                    DispatchQueue.main.async {
                        self.downloadError = error.localizedDescription
                        self.isDownloading = false
                        self.currentDownloadingModel = nil
                        continuation.resume(throwing: error)
                    }
                }
            }
            task.resume()
        }
    }

    /// Installs a CoreML encoder bundle atomically. Unzips into a scratch
    /// directory on the same volume as `destination` (required for
    /// FileManager.replaceItemAt/moveItem to be atomic — the scratch dir is a
    /// sibling of `destination`, i.e. inside modelsDirectory, so this holds),
    /// validates the extracted bundle, then swaps it into place. Nothing at
    /// `destination` is touched until validation passes, so a failure at any
    /// point leaves the previous install (if any) exactly as it was.
    ///
    /// `nonisolated` — derives the scratch dir from `destination` rather than
    /// re-reading the actor-isolated `modelsDirectory` property, so this can
    /// run straight from the URLSession completion handler (a background
    /// queue) without a main-actor hop.
    private nonisolated func installCoreMLBundle(zipPath: URL, destination: URL) throws {
        let fm = FileManager.default
        let scratchDir = destination.deletingLastPathComponent()
            .appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratchDir) }

        print("[ModelManager] Unzipping CoreML model from \(zipPath.path) to \(scratchDir.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", zipPath.path, "-d", scratchDir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            print("[ModelManager] Unzip failed with status: \(process.terminationStatus)")
            throw ModelError.unzipFailed
        }

        // HuggingFace's zip also contains a __MACOSX metadata folder alongside
        // the real bundle — ignore it. Exactly one other top-level directory,
        // named after the expected bundle, is what a well-formed archive looks
        // like; anything else (zero, several, wrong name) is rejected rather
        // than guessed at.
        let topLevel = try fm.contentsOfDirectory(at: scratchDir, includingPropertiesForKeys: [.isDirectoryKey])
        let candidates = topLevel.filter { entry in
            entry.lastPathComponent != "__MACOSX"
                && (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        guard candidates.count == 1, candidates[0].lastPathComponent == destination.lastPathComponent else {
            print("[ModelManager] Unexpected archive contents: \(topLevel.map(\.lastPathComponent))")
            throw ModelError.unexpectedArchiveContents
        }
        let extractedBundle = candidates[0]

        guard isValidCoreMLBundle(at: extractedBundle) else {
            print("[ModelManager] Extracted CoreML bundle failed structural validation")
            throw ModelError.corruptedCoreMLBundle
        }

        // replaceItemAt requires the destination to already exist (it errors
        // on a missing target) — moveItem covers the fresh-install case.
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: extractedBundle)
        } else {
            try fm.moveItem(at: extractedBundle, to: destination)
        }

        guard fm.fileExists(atPath: destination.path) else {
            print("[ModelManager] CoreML model not found after install at \(destination.path)")
            throw ModelError.moveFailed
        }

        print("[ModelManager] CoreML model installed successfully: \(destination.lastPathComponent)")
    }

    func deleteModel(model: TranscriptionModel) throws {
        let mainURL = modelURL(for: model)
        let coreMLURL = coreMLModelURL(for: model)

        if FileManager.default.fileExists(atPath: mainURL.path) {
            try FileManager.default.removeItem(at: mainURL)
            print("[ModelManager] Deleted main model: \(model.fileName)")
        }

        // The Metal-only shadow symlink (see TranscriptionService.shadowModelURL)
        // points at this exact filename one directory up — with the real .bin
        // gone, a leftover symlink here is just dangling garbage in
        // .metal-only/. Best-effort: a missing or already-clean shadow path is
        // not an error condition for a model deletion.
        removeMetalOnlyShadowSymlink(for: model)

        // largeV3Turbo and largeV3TurboQ5 share one CoreML encoder bundle (see
        // TranscriptionModel.coreMLFileName) — only remove it if no other
        // downloaded model still references the same bundle name, or that
        // model loses GPU acceleration until a re-download.
        let sharedByAnotherDownloadedModel = TranscriptionModel.allCases.contains { other in
            other != model && other.coreMLFileName == model.coreMLFileName && isModelDownloaded(model: other)
        }

        if !sharedByAnotherDownloadedModel && FileManager.default.fileExists(atPath: coreMLURL.path) {
            try FileManager.default.removeItem(at: coreMLURL)
            print("[ModelManager] Deleted CoreML model: \(model.coreMLFileName)")
        }
    }

    /// Removes `<Models>/.metal-only/<model's filename>` if it exists. Mirrors
    /// the layout `TranscriptionService.shadowModelURL` builds: same filename,
    /// one directory below the real models dir. Only removes an actual
    /// symlink — if something else ever occupies that path (it shouldn't;
    /// nothing else writes there), leave it alone rather than guess.
    private func removeMetalOnlyShadowSymlink(for model: TranscriptionModel) {
        let fm = FileManager.default
        let shadowPath = modelsDirectory
            .appendingPathComponent(AccelerationPolicyResolver.metalOnlyShadowDirectoryName, isDirectory: true)
            .appendingPathComponent(model.fileName)

        guard let attrs = try? fm.attributesOfItem(atPath: shadowPath.path),
              (attrs[.type] as? FileAttributeType) == .typeSymbolicLink else {
            return
        }

        try? fm.removeItem(at: shadowPath)
        print("[ModelManager] Removed stale Metal-only shadow symlink for \(model.fileName)")
    }

    /// Removes orphaned scratch directories left behind by a hard crash
    /// mid-install/mid-shadow-write: `.install-*` (CoreML unzip scratch dir,
    /// see `installCoreMLBundle`) and `.shadow-*` (the temp symlink name
    /// `TranscriptionService.shadowModelURL` renames into place). Both are
    /// cleaned up inline on every normal path (a `defer` for the former, an
    /// atomic `rename()` for the latter) — this only catches the case where
    /// the process died before that cleanup ran, so it's a best-effort sweep,
    /// not a correctness requirement for either mechanism.
    ///
    /// Called once at app startup (`AppDelegate.applicationDidFinishLaunching`)
    /// rather than on every `deleteModel`/`downloadModel` call: a crash is rare
    /// and the leftover directories are harmless clutter until the next
    /// launch, so there's no need to pay the directory scan on every model
    /// operation — once per process lifetime is enough to keep them from
    /// accumulating indefinitely.
    func cleanUpOrphanedScratchDirectories() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: modelsDirectory.path) else { return }

        for name in entries where name.hasPrefix(".install-") {
            try? fm.removeItem(at: modelsDirectory.appendingPathComponent(name))
        }

        let shadowDir = modelsDirectory
            .appendingPathComponent(AccelerationPolicyResolver.metalOnlyShadowDirectoryName, isDirectory: true)
        guard let shadowEntries = try? fm.contentsOfDirectory(atPath: shadowDir.path) else { return }

        for name in shadowEntries where name.hasPrefix(".shadow-") {
            try? fm.removeItem(at: shadowDir.appendingPathComponent(name))
        }
    }

    func downloadedModels() -> [TranscriptionModel] {
        TranscriptionModel.allCases.filter { isModelDownloaded(model: $0) }
    }

    enum ModelError: LocalizedError {
        case alreadyDownloading
        case downloadFailed
        case moveFailed
        case unzipFailed
        case httpError(statusCode: Int)
        case unexpectedArchiveContents
        case corruptedCoreMLBundle

        var errorDescription: String? {
            switch self {
            case .alreadyDownloading:
                return "A download is already in progress"
            case .downloadFailed:
                return "Download failed"
            case .moveFailed:
                return "Failed to move downloaded file"
            case .unzipFailed:
                return "Failed to unzip CoreML model"
            case .httpError(let statusCode):
                return "Server returned HTTP \(statusCode)"
            case .unexpectedArchiveContents:
                return "CoreML archive did not contain the expected model bundle"
            case .corruptedCoreMLBundle:
                return "Downloaded CoreML model failed validation"
            }
        }
    }
}
