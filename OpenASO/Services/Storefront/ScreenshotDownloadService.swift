import Foundation

struct ScreenshotDownloadJob: Identifiable, Sendable {
    let id: String
    let urlString: String
    let relativeDirectoryComponents: [String]
    let filenameStem: String
    let metadata: [String: String]
    let fallbackExtension: String

    init(
        id: String = UUID().uuidString,
        urlString: String,
        relativeDirectoryComponents: [String],
        filenameStem: String,
        metadata: [String: String] = [:],
        fallbackExtension: String = "jpg"
    ) {
        self.id = id
        self.urlString = urlString
        self.relativeDirectoryComponents = relativeDirectoryComponents
        self.filenameStem = filenameStem
        self.metadata = metadata
        self.fallbackExtension = fallbackExtension
    }
}

struct DownloadedScreenshot: Sendable {
    let jobID: String
    let urlString: String
    let relativePath: String
    let fileURL: URL
    let byteCount: Int
    let metadata: [String: String]
}

struct FailedScreenshotDownload: Sendable {
    let jobID: String
    let urlString: String
    let relativePath: String?
    let errorDescription: String
    let metadata: [String: String]
}

struct ScreenshotDownloadResult: Sendable {
    let completed: [DownloadedScreenshot]
    let failed: [FailedScreenshotDownload]

    var totalCount: Int {
        completed.count + failed.count
    }
}

final class ScreenshotDownloadService: Sendable {
    typealias DataProvider = @Sendable (URL) async throws -> (Data, URLResponse)
    typealias ProgressHandler = @Sendable (_ completed: Int, _ total: Int, _ failureCount: Int) async -> Void

    private let dataProvider: DataProvider

    init(dataProvider: @escaping DataProvider = ScreenshotDownloadService.urlSessionDataProvider) {
        self.dataProvider = dataProvider
    }

    func download(
        jobs: [ScreenshotDownloadJob],
        to destinationRoot: URL,
        maxConcurrentDownloads: Int = 4,
        progress: ProgressHandler? = nil
    ) async -> ScreenshotDownloadResult {
        guard !jobs.isEmpty else {
            await progress?(0, 0, 0)
            return ScreenshotDownloadResult(completed: [], failed: [])
        }

        await progress?(0, jobs.count, 0)

        let queue = ScreenshotDownloadJobQueue(jobs: jobs)
        let sink = ScreenshotDownloadResultSink(total: jobs.count, progress: progress)
        let workerCount = min(max(1, maxConcurrentDownloads), jobs.count)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    while let job = await queue.next() {
                        let outcome = await self.download(job: job, to: destinationRoot)
                        await sink.record(outcome)
                    }
                }
            }
        }

        return await sink.result()
    }

    private func download(
        job: ScreenshotDownloadJob,
        to destinationRoot: URL
    ) async -> ScreenshotDownloadOutcome {
        guard let url = URL(string: job.urlString) else {
            return .failed(FailedScreenshotDownload(
                jobID: job.id,
                urlString: job.urlString,
                relativePath: nil,
                errorDescription: "Invalid URL",
                metadata: job.metadata
            ))
        }

        do {
            let (data, response) = try await dataProvider(url)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                throw ScreenshotDownloadError.httpStatus(httpResponse.statusCode)
            }

            let fileExtension = Self.fileExtension(
                response: response,
                url: url,
                fallback: job.fallbackExtension
            )
            let relativePath = Self.relativePath(
                directoryComponents: job.relativeDirectoryComponents,
                filenameStem: job.filenameStem,
                fileExtension: fileExtension
            )
            let fileURL = destinationRoot.appendingPathComponent(relativePath, isDirectory: false)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])

            return .completed(DownloadedScreenshot(
                jobID: job.id,
                urlString: job.urlString,
                relativePath: relativePath,
                fileURL: fileURL,
                byteCount: data.count,
                metadata: job.metadata
            ))
        } catch {
            return .failed(FailedScreenshotDownload(
                jobID: job.id,
                urlString: job.urlString,
                relativePath: Self.relativePath(
                    directoryComponents: job.relativeDirectoryComponents,
                    filenameStem: job.filenameStem,
                    fileExtension: job.fallbackExtension
                ),
                errorDescription: error.localizedDescription,
                metadata: job.metadata
            ))
        }
    }

    static func sanitizedPathComponent(_ value: String, fallback: String = "Untitled") -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let sanitized = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(120))
    }

    private static func relativePath(
        directoryComponents: [String],
        filenameStem: String,
        fileExtension: String
    ) -> String {
        let directories = directoryComponents.map {
            sanitizedPathComponent($0, fallback: "Folder")
        }
        let filename = "\(sanitizedPathComponent(filenameStem, fallback: "Screenshot")).\(normalizedExtension(fileExtension))"
        return (directories + [filename]).joined(separator: "/")
    }

    private static func fileExtension(response: URLResponse, url: URL, fallback: String) -> String {
        if let mimeType = response.mimeType,
           let mimeExtension = fileExtension(forMIMEType: mimeType) {
            return mimeExtension
        }

        let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pathExtension.isEmpty {
            return pathExtension
        }

        return fallback
    }

    private static func fileExtension(forMIMEType mimeType: String) -> String? {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        case "image/heic":
            return "heic"
        default:
            return nil
        }
    }

    private static func normalizedExtension(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return normalized.isEmpty ? "jpg" : sanitizedPathComponent(normalized, fallback: "jpg")
    }

    private static func urlSessionDataProvider(url: URL) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(from: url)
    }
}

private enum ScreenshotDownloadOutcome: Sendable {
    case completed(DownloadedScreenshot)
    case failed(FailedScreenshotDownload)
}

private actor ScreenshotDownloadJobQueue {
    private var jobs: [ScreenshotDownloadJob]
    private var nextIndex = 0

    init(jobs: [ScreenshotDownloadJob]) {
        self.jobs = jobs
    }

    func next() -> ScreenshotDownloadJob? {
        guard nextIndex < jobs.count else { return nil }
        let job = jobs[nextIndex]
        nextIndex += 1
        return job
    }
}

private actor ScreenshotDownloadResultSink {
    private let total: Int
    private let progress: ScreenshotDownloadService.ProgressHandler?
    private var completed: [DownloadedScreenshot] = []
    private var failed: [FailedScreenshotDownload] = []

    init(total: Int, progress: ScreenshotDownloadService.ProgressHandler?) {
        self.total = total
        self.progress = progress
    }

    func record(_ outcome: ScreenshotDownloadOutcome) async {
        switch outcome {
        case .completed(let download):
            completed.append(download)
        case .failed(let failure):
            failed.append(failure)
        }

        await progress?(completed.count + failed.count, total, failed.count)
    }

    func result() -> ScreenshotDownloadResult {
        ScreenshotDownloadResult(completed: completed, failed: failed)
    }
}

private enum ScreenshotDownloadError: LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let statusCode):
            return "HTTP \(statusCode)"
        }
    }
}
