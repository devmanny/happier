import Foundation
import Testing
@testable import HappierKit

@Suite struct StructuredQuestionnaireTests {
    private let input: JSONValue = ["questions": [
        ["id": "destination", "question": "Where should it go?", "header": "Destination", "multiSelect": true,
         "options": [["label": "Calendar", "value": "calendar"], ["label": "Reminder", "choice": "reminder"]]],
        ["question": "Any notes?", "freeform": true],
    ]]

    private func call(_ input: JSONValue, result: JSONValue? = nil) -> ToolCall {
        ToolCall(id: "question", itemId: "question-row:0", name: "AskUserQuestion", input: input,
                 title: nil, state: .completed, result: result, permission: nil, createdAt: Date(timeIntervalSince1970: 10))
    }

    private func row(_ input: JSONValue, id: String = "question-row", seq: Int = 1) -> TranscriptMessage {
        TranscriptMessage(id: id, seq: seq, localId: nil, createdAt: Date(timeIntervalSince1970: 10), record: [
            "role": "agent", "content": ["type": "codex", "data": [
                "type": "tool-call", "callId": "question", "name": "AskUserQuestion", "input": input,
            ]],
        ])
    }

    private func state(_ input: JSONValue, answers: JSONValue, status: String = "approved") -> JSONValue {
        ["completedRequests": ["question": ["tool": "AskUserQuestion", "kind": "user_action",
            "arguments": input, "createdAt": 10_000, "status": .string(status), "structuredAnswersV1": answers]]]
    }

    private func questions(_ transcript: Transcript) throws -> StructuredQuestionnaire {
        let tool = try #require(transcript.items.compactMap { if case .toolCall(let tool) = $0 { tool } else { nil } }.first)
        return try #require(tool.questionnaire)
    }

    @Test func modernAgentStateAnswersRemainExactAndMapIdsToQuestions() throws {
        var transcript = Transcript()
        transcript.apply([row(input)])
        transcript.apply(agentState: state(input, answers: ["destination": ["calendar", "reminder"], "Any notes?": ["Manny, Wen\n  keep spacing  "]]))
        let model = try questions(transcript)
        #expect(model.isAnswered)
        #expect(model.questions.map(\.id) == ["Where should it go?", "Any notes?"])
        #expect(model.questions[0].answers == ["calendar", "reminder"])
        #expect(model.questions[0].label(for: "calendar") == "Calendar")
        #expect(model.questions[1].answers == ["Manny, Wen\n  keep spacing  "])
    }

    @Test func aVisiblePendingPlaceholderSurvivesCompletionAndLateHistoryWithoutDuplication() throws {
        var transcript = Transcript()
        transcript.apply(agentState: ["requests": ["question": ["tool": "AskUserQuestion", "arguments": input, "createdAt": 10_000]]])
        let pendingId = try #require(transcript.items.first?.id)
        transcript.apply(agentState: state(input, answers: ["destination": ["calendar"], "Any notes?": ["No notes"]]))
        #expect(transcript.items.first?.id == pendingId)
        #expect(try questions(transcript).isAnswered)
        transcript.apply([row(input)])
        #expect(transcript.items.count == 1)
        #expect(try questions(transcript).questions[0].answers == ["calendar"])
    }

    @Test func unseenCompletedRequestsDoNotInjectQuestionsFromOutsideLoadedHistory() {
        var transcript = Transcript()
        transcript.apply(agentState: state(input, answers: ["destination": ["calendar"], "Any notes?": ["No notes"]]))
        #expect(transcript.items.isEmpty)
    }

    @Test func retainedQuestionStaysBeforeLaterAgentMessages() throws {
        var transcript = Transcript()
        transcript.apply(agentState: ["requests": ["question": ["tool": "AskUserQuestion", "arguments": input, "createdAt": 10_000]]])
        transcript.apply(agentState: state(input, answers: ["destination": ["calendar"], "Any notes?": ["No notes"]]))
        transcript.apply([TranscriptMessage(id: "later", seq: 2, localId: nil, createdAt: Date(timeIntervalSince1970: 20), record: [
            "role": "agent", "content": ["type": "codex", "data": ["type": "message", "message": "Continuing"]],
        ])])
        #expect(transcript.items.count == 2)
        #expect(transcript.items.first?.id == "request:question")
        #expect(try questions(transcript).isAnswered)
    }

    @Test func legacyAnswersRemainOneExactString() throws {
        var transcript = Transcript()
        transcript.apply([row(input)])
        transcript.apply(agentState: ["completedRequests": ["question": ["tool": "AskUserQuestion", "arguments": input,
            "status": "approved", "answers": ["Where should it go?": "Calendar, Reminder", "Any notes?": "Wen, Manny"]]]])
        let model = try questions(transcript)
        #expect(model.isAnswered)
        #expect(model.questions[0].answers == ["Calendar, Reminder"])
        #expect(model.questions[1].answers == ["Wen, Manny"])
    }

    @Test func toolResultAloneRestoresAnsweredHistoryIncludingSerializedResults() throws {
        let result: JSONValue = ["status": "answered", "answers": ["destination": ["calendar", "reminder"], "Any notes?": ["Exact, value"]]]
        let encoded = String(decoding: try result.encoded(), as: UTF8.self)
        for value in [result, .string(encoded), .array([["type": "text", "text": .string(encoded)]])] {
            let model = try #require(call(input, result: value).questionnaire)
            #expect(model.isAnswered)
            #expect(model.questions[0].answers == ["calendar", "reminder"])
            #expect(model.questions[1].answers == ["Exact, value"])
        }
    }

    @Test(arguments: ["cancelled", "declined", "denied", "abandoned", "failed"])
    func nonAnsweredResultsNeverGetAnAnsweredState(_ status: String) throws {
        let model = try #require(call(input, result: ["status": .string(status), "answers": ["destination": ["calendar"], "Any notes?": ["stale"]]]).questionnaire)
        #expect(!model.isAnswered)
        #expect(model.questions.allSatisfy { $0.answers == nil })
    }

    @Test func pendingOrFailedToolDoesNotReuseOldAnswers() throws {
        var tool = call(input, result: ["answers": ["destination": ["calendar"], "Any notes?": ["stale"]]])
        tool.permission = ToolPermission(id: "question", status: .pending, kind: .userAction, reason: nil, decision: nil)
        #expect(tool.questionnaire?.isAnswered == false)
        tool.permission = nil
        tool.state = .error
        #expect(tool.questionnaire?.isAnswered == false)
        tool.state = .completed
        tool.result = nil
        tool.permission = ToolPermission(id: "question", status: .approved, kind: .userAction, reason: nil, decision: nil)
        #expect(tool.questionnaire?.isAnswered == false)
    }

    @Test func explicitEmptyAnswerIsOnlyAnsweredWhenTheQuestionAllowsIt() throws {
        for allowed in [true, false] {
            let input: JSONValue = ["questions": [["question": "Optional note", "freeform": ["allowEmpty": .bool(allowed)]]]]
            let model = try #require(call(input, result: ["answers": ["Optional note": [""]]]).questionnaire)
            #expect(model.isAnswered == allowed)
            #expect(model.questions[0].answers == [""])
        }
    }

    private func resultOnlyRow(_ result: JSONValue, isError: Bool = false) -> TranscriptMessage {
        TranscriptMessage(id: "question-result", seq: 2, localId: nil, createdAt: Date(timeIntervalSince1970: 20), record: [
            "role": "agent", "content": ["type": "codex", "data": [
                "type": "tool-call-result", "callId": "question", "output": result, "isError": .bool(isError),
            ]],
        ])
    }

    private func visibleAnsweredPlaceholder() -> Transcript {
        var transcript = Transcript()
        transcript.apply(agentState: ["requests": ["question": ["tool": "AskUserQuestion", "arguments": input, "createdAt": 10_000]]])
        transcript.apply(agentState: state(input, answers: ["destination": ["calendar"], "Any notes?": ["Exact note"]]))
        return transcript
    }

    @Test func aLateResultOnlyCancellationRetiresTheVisibleAnsweredPlaceholder() throws {
        var transcript = visibleAnsweredPlaceholder()
        let result: JSONValue = ["status": "cancelled"]
        transcript.apply([resultOnlyRow(result)])
        #expect(transcript.items.count == 1)
        let tool = try #require(transcript.items.compactMap { if case .toolCall(let tool) = $0 { tool } else { nil } }.first)
        #expect(tool.itemId == "request:question")
        #expect(tool.result == result)
        #expect(tool.questionnaire?.isAnswered == false)
    }

    @Test func aLateResultOnlyErrorRetiresTheVisibleAnsweredPlaceholder() throws {
        var transcript = visibleAnsweredPlaceholder()
        let result: JSONValue = ["error": "Synthetic tool failure"]
        transcript.apply([resultOnlyRow(result, isError: true)])
        #expect(transcript.items.count == 1)
        let tool = try #require(transcript.items.compactMap { if case .toolCall(let tool) = $0 { tool } else { nil } }.first)
        #expect(tool.itemId == "request:question")
        #expect(tool.state == .error)
        #expect(tool.result == result)
        #expect(tool.questionnaire?.isAnswered == false)
    }

    @Test func aLateResultOnlyAnswerCompletesTheSameVisiblePlaceholder() throws {
        var transcript = visibleAnsweredPlaceholder()
        let result: JSONValue = ["status": "answered", "answers": ["destination": ["calendar"], "Any notes?": ["Exact note"]]]
        transcript.apply([resultOnlyRow(result)])
        #expect(transcript.items.count == 1)
        let tool = try #require(transcript.items.compactMap { if case .toolCall(let tool) = $0 { tool } else { nil } }.first)
        #expect(tool.itemId == "request:question")
        #expect(tool.state == .completed)
        #expect(tool.result == result)
        #expect(tool.questionnaire?.isAnswered == true)
        #expect(tool.questionnaire?.questions[1].answers == ["Exact note"])
    }

}
