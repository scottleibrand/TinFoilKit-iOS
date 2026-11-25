import Foundation

struct LibraryAnswerPrompt: Codable, Equatable {
    struct Passage: Codable, Equatable {
        let sourceNumber: Int
        let title: String
        let excerpt: String
    }

    static let maximumHouseholdNotesLength = 4_000

    let question: String
    let passages: [Passage]
    let householdNotes: String?

    init(question: String, passages: [(title: String, excerpt: String)], householdNotes: String? = nil) {
        self.question = String(question.prefix(500))
        self.householdNotes = householdNotes.map { String($0.prefix(Self.maximumHouseholdNotesLength)) }
        self.passages = passages.enumerated().map { index, passage in
            Passage(sourceNumber: index + 1, title: String(passage.title.prefix(120)),
                    excerpt: String(passage.excerpt.prefix(520)))
        }
    }

    func encode() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
