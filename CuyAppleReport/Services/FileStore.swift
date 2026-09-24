import Foundation

enum FileStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "CuyAppleReport", directoryHint: .isDirectory)
    }

    static func saveScreenshot(from remoteURL: URL, submissionId: String, index: Int) async throws -> URL {
        let (data, response) = try await CorporateTrust.urlSession.data(from: remoteURL)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw ASCError.invalidResponse
        }
        let folder = root.appending(path: "screenshots/\(submissionId)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = remoteURL.pathExtension.isEmpty ? "png" : remoteURL.pathExtension
        let path = folder.appending(path: "\(index).\(ext)")
        try data.write(to: path, options: .atomic)
        return path
    }

    static func saveCrashLog(_ text: String, submissionId: String) throws -> URL {
        let folder = root.appending(path: "crashlogs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(submissionId).txt")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    static func removeLocalFiles(at paths: [String]) {
        let rootPath = root.standardizedFileURL.path + "/"
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path.hasPrefix(rootPath) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
