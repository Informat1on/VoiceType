import Foundation
import Combine

@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?

    private var modelsDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let voiceTypeDirectory = applicationSupport.appendingPathComponent("VoiceType", isDirectory: true)
        let modelsDir = voiceTypeDirectory.appendingPathComponent("Models", isDirectory: true)

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
        let coreMLPath = coreMLModelURL(for: model).path
        return FileManager.default.fileExists(atPath: coreMLPath) && isDirectoryNotEmpty(path: coreMLPath)
    }

    private func isDirectoryNotEmpty(path: String) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return !contents.isEmpty
    }

    func downloadModel(model: TranscriptionModel) async throws {
        guard !isDownloading else {
            throw ModelError.alreadyDownloading
        }

        let needsMainModel = !isModelDownloaded(model: model)
        let needsCoreML = !isCoreMLModelDownloaded(model: model)

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

                do {
                    let fm = FileManager.default
                    
                    if destination.pathExtension == "mlmodelc" {
                        let zipPath = tempURL
                        let unzipDestination = destination.deletingLastPathComponent()
                        
                        print("[ModelManager] Unzipping CoreML model from \(zipPath.path) to \(unzipDestination.path)")
                        
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                        process.arguments = ["-q", "-o", zipPath.path, "-d", unzipDestination.path]
                        
                        try process.run()
                        process.waitUntilExit()
                        
                        guard process.terminationStatus == 0 else {
                            print("[ModelManager] Unzip failed with status: \(process.terminationStatus)")
                            throw ModelError.unzipFailed
                        }
                        
                        guard fm.fileExists(atPath: destination.path) else {
                            print("[ModelManager] CoreML model not found after unzip at \(destination.path)")
                            throw ModelError.moveFailed
                        }
                        
                        print("[ModelManager] CoreML model unzipped successfully: \(destination.lastPathComponent)")
                    } else {
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

    func deleteModel(model: TranscriptionModel) throws {
        let mainURL = modelURL(for: model)
        let coreMLURL = coreMLModelURL(for: model)
        
        if FileManager.default.fileExists(atPath: mainURL.path) {
            try FileManager.default.removeItem(at: mainURL)
            print("[ModelManager] Deleted main model: \(model.fileName)")
        }
        
        if FileManager.default.fileExists(atPath: coreMLURL.path) {
            try FileManager.default.removeItem(at: coreMLURL)
            print("[ModelManager] Deleted CoreML model: \(model.coreMLFileName)")
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
            }
        }
    }
}
