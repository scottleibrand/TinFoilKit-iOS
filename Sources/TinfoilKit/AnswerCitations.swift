import Foundation

enum AnswerCitations {
    static func indices(in answer: String, sourceCount: Int) -> [Int] {
        var indices: Set<Int> = []
        for match in answer.matches(of: citation) {
            guard let number = number(in: match.output), number > 0, number <= sourceCount else { return [] }
            indices.insert(number - 1)
        }
        return indices.sorted()
    }

    // A citation completes the text before it. Hold back any text the stream has
    // started after the last citation until the model supplies a source for it.
    static func completedPrefix(in answer: String, sourceCount: Int) -> String? {
        guard let last = answer.matches(of: citation).last,
              !indices(in: answer, sourceCount: sourceCount).isEmpty else { return nil }
        let tail = answer[last.range.upperBound...].prefix { terminalPunctuation.contains($0) }
        let prefix = String(answer[..<tail.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return isComplete(prefix, sourceCount: sourceCount) ? prefix : nil
    }

    static func isComplete(_ answer: String, sourceCount: Int) -> Bool {
        guard !indices(in: answer, sourceCount: sourceCount).isEmpty else { return false }
        return answer.split(whereSeparator: \.isNewline).allSatisfy { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return true }
            guard text.first != "[", let last = text.matches(of: citation).last else { return false }
            return text[last.range.upperBound...].allSatisfy { terminalPunctuation.contains($0) }
        }
    }

    static func linkedText(_ answer: String, sourceCount: Int) -> AttributedString {
        var text = AttributedString()
        var cursor = answer.startIndex
        for occurrence in answer.matches(of: citation) {
            let match = occurrence.range
            text.append(AttributedString(String(answer[cursor..<match.lowerBound])))
            var label = AttributedString(String(answer[match]))
            if let number = number(in: answer[match]), number > 0, number <= sourceCount {
                label.link = URL(string: "tinfoil-source://article/\(number)")
            }
            text.append(label)
            cursor = match.upperBound
        }
        text.append(AttributedString(String(answer[cursor...])))
        return text
    }

    static func sourceIndex(from url: URL, sourceCount: Int) -> Int? {
        guard url.scheme == "tinfoil-source", url.host == "article",
              let number = Int(url.lastPathComponent), number > 0, number <= sourceCount else { return nil }
        return number - 1
    }

    private static func number(in citation: Substring) -> Int? {
        Int(citation.dropFirst().dropLast())
    }

    private static let terminalPunctuation: Set<Character> = [".", "!", "?", ")", "”", "’", "\""]

    private static let citation = #/\[[0-9]+\]/#
}
