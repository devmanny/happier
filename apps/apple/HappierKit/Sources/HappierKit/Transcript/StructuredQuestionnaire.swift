import Foundation

/// One projection of question descriptors for the live form and its answered history.
public struct StructuredQuestionnaire: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let label: String
        public let value: String
        public let description: String?
    }

    public struct Question: Identifiable, Equatable, Sendable {
        /// The protocol response key is the full question, falling back to its header.
        public let id: String
        public let header: String?
        public let multi: Bool
        public let options: [Option]
        public let typesAnswer: Bool
        public let placeholder: String?
        public let allowsEmpty: Bool
        public let answers: [String]?

        public func label(for answer: String) -> String {
            options.first { $0.value == answer }?.label ?? answer
        }
    }

    public let questions: [Question]
    public let isAnswered: Bool

    public init?(_ tool: ToolCall) {
        guard tool.isQuestion, let raw = tool.input["questions"]?.arrayValue, !raw.isEmpty else { return nil }
        let result = Self.resultPayload(tool.result)
        let rejected = ["cancelled", "canceled", "declined", "denied", "abandoned", "error", "failed", "aborted"]
            .contains(result?["status"]?.stringValue ?? "")
        let canShowAnswers = tool.state != .error && !rejected
            && (tool.permission == nil || tool.permission?.status == .approved)
        let recorded = canShowAnswers
            ? tool.permission?.answers ?? Self.decodeAnswers(result?["answers"])
            : nil

        var questions: [Question] = []
        var seenKeys: Set<String> = []
        for descriptor in raw {
            guard let key = Self.nonblank(descriptor["question"]) ?? Self.nonblank(descriptor["header"]) else { return nil }
            let keys = [Self.nonblank(descriptor["id"]), key].compactMap { $0 }
            guard !keys.contains(where: { seenKeys.contains($0) }) else { return nil }
            seenKeys.formUnion(keys)
            let options = (descriptor["options"]?.arrayValue ?? []).compactMap { option -> Option? in
                if let value = Self.nonblank(option) {
                    return Option(label: value, value: value, description: nil)
                }
                guard let value = Self.nonblank(option["value"]) ?? Self.nonblank(option["choice"]) ?? Self.nonblank(option["label"]) else { return nil }
                return Option(label: Self.nonblank(option["label"]) ?? value, value: value, description: option["description"]?.stringValue)
            }
            let freeform = descriptor["freeform"]
            let isFreeform = freeform?.boolValue == true || freeform?.objectValue != nil
            let answers = keys.compactMap { recorded?[$0] }.first
            questions.append(Question(
                id: key, header: descriptor["header"]?.stringValue,
                multi: descriptor["multiSelect"]?.boolValue == true || descriptor["multiple"]?.boolValue == true,
                options: options, typesAnswer: isFreeform || options.isEmpty,
                placeholder: freeform?["placeholder"]?.stringValue,
                allowsEmpty: freeform?["allowEmpty"]?.boolValue == true,
                answers: answers))
        }
        self.questions = questions
        isAnswered = questions.allSatisfy { question in
            guard let answers = question.answers, !answers.isEmpty else { return false }
            return question.allowsEmpty || answers.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    /// Modern arrays and legacy strings are both recorded formats; strings are never split.
    static func decodeAnswers(_ value: JSONValue?) -> [String: [String]]? {
        guard let value else { return nil }
        let decoded: JSONValue
        if let text = value.stringValue {
            guard let parsed = try? JSONValue.parse(Data(text.utf8)) else { return nil }
            decoded = parsed
        } else { decoded = value }
        guard let object = decoded.objectValue else { return nil }
        var answers: [String: [String]] = [:]
        for (key, value) in object {
            if let text = value.stringValue { answers[key] = [text] }
            else if let values = value.arrayValue, values.allSatisfy({ $0.stringValue != nil }) {
                answers[key] = values.compactMap(\.stringValue)
            }
        }
        return answers.isEmpty ? nil : answers
    }

    private static func nonblank(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func resultPayload(_ value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }
        if let text = value.stringValue { return try? JSONValue.parse(Data(text.utf8)) }
        if value["answers"] != nil || value["status"] != nil { return value }
        if let content = value["content"] { return resultPayload(content) }
        if let items = value.arrayValue, items.count == 1 { return resultPayload(items[0]["text"]) }
        return nil
    }
}

public extension ToolCall {
    var isQuestion: Bool { name == "AskUserQuestion" || name == "ask_user_question" }
    var questionnaire: StructuredQuestionnaire? { StructuredQuestionnaire(self) }
}
