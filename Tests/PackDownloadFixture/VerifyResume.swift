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

        let received: Data
        do {
            let (file, _) = try await session.download(from: url)
            received = try Data(contentsOf: file)
            print("URLSession recovered the broken connection internally.")
        } catch {
            let resumeKey = NSURLSessionDownloadTaskResumeData
            guard let resume = (error as NSError).userInfo[resumeKey] as? Data, !resume.isEmpty else { throw error }
            try resume.write(to: resumeFile, options: .atomic)
            let (file, _) = try await session.download(resumeFrom: Data(contentsOf: resumeFile))
            received = try Data(contentsOf: file)
            print("Recreated the download from persisted URLSession resume data.")
        }
        guard received == expected else { throw FixtureError.incorrectBytes }
        print("The resumed file matches the original bytes.")
    }

    private enum FixtureError: Error { case incorrectBytes }
}
