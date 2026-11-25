import Foundation

enum OnlineAskClient {
    private static let instructions = """
        Answer the user's question using the web search tool and cite the sources that support the answer.
        Prefer primary sources. When a question depends on a location, date, or other missing detail,
        say what the evidence establishes and what additional detail is needed. Do not invent a source.
        """

    private static let session = makeSession(allowMetered: true)
    private static let unmeteredSession = makeSession(allowMetered: false)

    private static func makeSession(allowMetered: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        configuration.allowsCellularAccess = allowMetered
        configuration.allowsExpensiveNetworkAccess = allowMetered
        configuration.allowsConstrainedNetworkAccess = allowMetered
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    static func ask(_ question: String, provider: OnlineAskProvider, apiKey: String,
                    allowMetered: Bool = true) async throws -> OnlineAskResponse {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw ClientError.emptyQuestion }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw ClientError.invalidKey
        }
        let request = try makeRequest(question: question, provider: provider, key: key)
        let connection = allowMetered ? session : unmeteredSession
        let (bytes, response) = try await connection.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        switch response.statusCode {
        case 200..<300:
            return try decode(bytes, from: provider)
        case 401, 403:
            throw ClientError.providerUnauthorized
        case 429:
            throw ClientError.providerLimited
        default:
            throw ClientError.providerFailed(response.statusCode)
        }
    }

    private static func makeRequest(question: String, provider: OnlineAskProvider, key: String) throws -> URLRequest {
        let endpoint: URL
        let headers: [String: String]
        let body: [String: Any]
        switch provider {
        case .gpt:
            endpoint = URL(string: "https://api.openai.com/v1/responses")!
            headers = ["Authorization": "Bearer \(key)"]
            body = [
                "model": "gpt-6.1-terra", "instructions": instructions, "input": question,
                "store": false, "tools": [["type": "web_search"]],
                "tool_choice": ["type": "web_search"],
                "include": ["web_search_call.action.sources"]
            ]
        case .claude:
            endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
            headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
            body = [
                "model": "claude-sonnet-5-5", "system": instructions, "max_tokens": 4096,
                "messages": [["role": "user", "content": question]],
                "tools": [["type": "web_search_20250305", "name": "web_search"]]
            ]
        case .gemini:
            endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent")!
            headers = ["x-goog-api-key": key]
            body = [
                "systemInstruction": ["parts": [["text": instructions]]],
                "contents": [["role": "user", "parts": [["text": question]]]],
                "tools": [["google_search": [:] as [String: String]]]
            ]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func decode(_ data: Data, from provider: OnlineAskProvider) throws -> OnlineAskResponse {
        let decoder = JSONDecoder()
        let result: OnlineAskResponse
        switch provider {
        case .gpt:
            result = try decodeGPT(decoder.decode(GPTResult.self, from: data))
        case .claude:
            result = try decodeClaude(decoder.decode(ClaudeResult.self, from: data))
        case .gemini:
            result = try decodeGemini(decoder.decode(GeminiResult.self, from: data))
        }
        guard !result.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !result.citations.isEmpty else { throw ClientError.noGroundedAnswer }
        return result
    }

    private static func decodeGPT(_ response: GPTResult) throws -> OnlineAskResponse {
        guard response.status == nil || response.status == "completed" else {
            throw ClientError.incompleteAnswer
        }
        var sources = Sources()
        var answer: [String] = []
        var hasInlineCitation = false
        for item in response.output where item.type == "message" {
            for part in item.content ?? [] where part.type == "output_text" {
                guard let text = part.text else { continue }
                let scalars = text.unicodeScalars
                var links: [String.Index: [Int]] = [:]
                for annotation in part.annotations ?? [] where annotation.type == "url_citation" {
                    let end = annotation.end_index.flatMap { scalars.index(scalars.startIndex, offsetBy: max(0, $0), limitedBy: scalars.endIndex) }
                    guard let source = sources.add(annotation.url, title: annotation.title, excerpt: nil) else { continue }
                    hasInlineCitation = true
                    links[end ?? text.endIndex, default: []].append(source)
                }
                answer.append(annotate(text, links: links, citations: sources.citations))
            }
        }
        for item in response.output where item.type == "web_search_call" {
            for source in item.action?.sources ?? [] {
                _ = sources.add(source.url, title: source.title, excerpt: nil)
            }
        }
        guard hasInlineCitation else { throw ClientError.noGroundedAnswer }
        return OnlineAskResponse(answer: answer.joined(separator: "\n\n"), citations: sources.citations)
    }

    private static func decodeClaude(_ response: ClaudeResult) throws -> OnlineAskResponse {
        guard response.stop_reason != "max_tokens", response.stop_reason != "pause_turn" else {
            throw ClientError.incompleteAnswer
        }
        var sources = Sources()
        var answer: [String] = []
        for block in response.content where block.type == "text" {
            guard let text = block.text else { continue }
            let references = (block.citations ?? []).compactMap { citation -> Int? in
                guard citation.type == "web_search_result_location" else { return nil }
                return sources.add(citation.url, title: citation.title, excerpt: citation.cited_text)
            }
            answer.append(annotate(text, links: [text.endIndex: references], citations: sources.citations))
        }
        // Search-result blocks describe hits returned to Claude. Persist the sources actually cited in text.
        return OnlineAskResponse(answer: answer.joined(separator: "\n\n"), citations: sources.citations)
    }

    private static func decodeGemini(_ response: GeminiResult) throws -> OnlineAskResponse {
        guard let candidate = response.candidates?.first,
              candidate.finishReason == nil || candidate.finishReason == "STOP",
              let grounding = candidate.groundingMetadata,
              let entryPoint = grounding.searchEntryPoint?.renderedContent,
              !entryPoint.isEmpty else { throw ClientError.noGroundedAnswer }
        var sources = Sources()
        let citationIDs = (grounding.groundingChunks ?? []).map { chunk in
            sources.add(chunk.web?.uri, title: chunk.web?.title, excerpt: nil)
        }
        let answer = (candidate.content?.parts ?? []).enumerated().compactMap { partIndex, part -> String? in
            guard part.thought != true, let text = part.text else { return nil }
            var links: [String.Index: [Int]] = [:]
            for support in grounding.groundingSupports ?? [] where (support.segment.partIndex ?? 0) == partIndex {
                let references = support.groundingChunkIndices.compactMap { index in
                    citationIDs.indices.contains(index) ? citationIDs[index] : nil
                }
                let match = text.utf8.index(text.utf8.startIndex, offsetBy: max(0, support.segment.endIndex), limitedBy: text.utf8.endIndex)
                let end = match.flatMap { String.Index($0, within: text) } ?? text.endIndex
                links[end, default: []].append(contentsOf: references)
            }
            return annotate(text, links: links, citations: sources.citations)
        }
        return OnlineAskResponse(answer: answer.joined(separator: "\n\n"), citations: sources.citations,
                                 searchEntryPointHTML: entryPoint, cacheAllowed: false)
    }

    private static func annotate(_ text: String, links: [String.Index: [Int]], citations: [OnlineAskCitation]) -> String {
        var result = ""
        var start = text.startIndex
        for end in links.keys.sorted() {
            var seen: Set<Int> = []
            result += text[start..<end]
            for index in links[end] ?? [] where seen.insert(index).inserted {
                let url = citations[index].url.absoluteString
                result += " [\(index + 1)](<\(url)>)"
            }
            start = end
        }
        result += text[start...]
        return result
    }

    private struct Sources {
        var citations: [OnlineAskCitation] = []
        var indices: [URL: Int] = [:]

        mutating func add(_ url: URL?, title: String?, excerpt: String?) -> Int? {
            guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
            let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = excerpt?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = indices[url] {
                let old = citations[index]
                let combined: String
                if let excerpt, !excerpt.isEmpty, old.excerpt?.contains(excerpt) != true {
                    combined = [old.excerpt, excerpt].compactMap { $0 }.joined(separator: "\n\n")
                } else {
                    combined = old.excerpt ?? ""
                }
                let cleanedTitle = title.flatMap { $0.isEmpty ? nil : $0 }
                let improvedTitle = old.title == host ? cleanedTitle ?? old.title : old.title
                citations[index] = OnlineAskCitation(url: url, title: improvedTitle, excerpt: combined.isEmpty ? nil : combined)
                return index
            }
            let index = citations.count
            indices[url] = index
            citations.append(OnlineAskCitation(url: url, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? host,
                                              excerpt: excerpt?.isEmpty == false ? excerpt : nil))
            return index
        }
    }

    private struct GPTResult: Decodable {
        let status: String?
        let output: [Output]

        struct Output: Decodable {
            let type: String
            let content: [Part]?
            let action: Action?

            struct Action: Decodable {
                let sources: [Source]?
                struct Source: Decodable {
                    let url: URL?
                    let title: String?
                }
            }

            struct Part: Decodable {
                let type: String
                let text: String?
                let annotations: [Annotation]?

                struct Annotation: Decodable {
                    let type: String
                    let url: URL?
                    let title: String?
                    let end_index: Int?
                }
            }
        }
    }

    private struct ClaudeResult: Decodable {
        let stop_reason: String?
        let content: [Block]

        struct Block: Decodable {
            let type: String
            let text: String?
            let citations: [Citation]?

            struct Citation: Decodable {
                let type: String
                let url: URL?
                let title: String?
                let cited_text: String?
            }
        }
    }

    private struct GeminiResult: Decodable {
        let candidates: [Candidate]?

        struct Candidate: Decodable {
            let content: Content?
            let finishReason: String?
            let groundingMetadata: Grounding?

            struct Content: Decodable {
                let parts: [Part]
                struct Part: Decodable {
                    let text: String?
                    let thought: Bool?
                }
            }

            struct Grounding: Decodable {
                let groundingChunks: [Chunk]?
                let groundingSupports: [Support]?
                let searchEntryPoint: EntryPoint?

                struct Chunk: Decodable {
                    let web: Web?
                    struct Web: Decodable {
                        let uri: URL?
                        let title: String?
                    }
                }

                struct Support: Decodable {
                    let groundingChunkIndices: [Int]
                    let segment: Segment
                    struct Segment: Decodable {
                        let partIndex: Int?
                        let endIndex: Int
                    }
                }

                struct EntryPoint: Decodable {
                    let renderedContent: String?
                }
            }
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private enum ClientError: LocalizedError {
        case emptyQuestion, invalidKey, invalidResponse, providerUnauthorized, providerLimited
        case providerFailed(Int), incompleteAnswer, noGroundedAnswer

        var errorDescription: String? {
            switch self {
            case .emptyQuestion: "Enter a question to ask."
            case .invalidKey: "Enter a valid API key for this provider."
            case .invalidResponse: "The provider returned an unexpected response."
            case .providerUnauthorized: "The provider denied access. Check the API key and web search access."
            case .providerLimited: "The provider reached a usage limit. Check its billing or try again later."
            case let .providerFailed(status): "The online provider returned HTTP \(status)."
            case .incompleteAnswer: "The provider stopped before completing a sourced answer."
            case .noGroundedAnswer: "The provider did not return an answer with web sources."
            }
        }
    }
}
