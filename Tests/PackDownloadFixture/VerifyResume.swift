import Foundation

@main
struct VerifyResume {
    static func main() async throws {
        let url = URL(string: CommandLine.arguments[1])!
        let directory = URL(filePath: CommandLine.arguments[2], directoryHint: .isDirectory)
        let expected = try Data(contentsOf: directory.appending(path: "expected"))
        let resumeFile = directory.appending(path: "resume")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        for attempt in 0...3 {
            do {
                let file: URL
                if attempt == 0 {
                    (file, _) = try await session.download(from: url)
                } else {
                    (file, _) = try await session.download(resumeFrom: Data(contentsOf: resumeFile))
                }
                guard try Data(contentsOf: file) == expected else { throw FixtureError.incorrectBytes }
                print("The resumed file matches the original bytes.")
                return
            } catch {
                let resumeKey = NSURLSessionDownloadTaskResumeData
                guard attempt < 3,
                      let resume = (error as NSError).userInfo[resumeKey] as? Data, !resume.isEmpty else { throw error }
                try resume.write(to: resumeFile, options: .atomic)
                print("Persisted URLSession resume data after interruption.")
            }
        }
    }

    private enum FixtureError: Error { case incorrectBytes }
}
