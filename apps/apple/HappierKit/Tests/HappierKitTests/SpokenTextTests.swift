import Testing
@testable import HappierKit

/// "Speak" reads what the bubble shows, not its Markdown source.
@Suite struct SpokenTextTests {
    @Test func readsProseWithoutMarkdownSyntax() {
        let text = """
        ## Resumen
        Ya quedó **todo** listo con `happier` y [la guía](https://x.dev).

        - Primer punto
        - Segundo punto
        """
        #expect(SpokenText.from(markdown: text) == "Resumen\nYa quedó todo listo con happier y la guía.\nPrimer punto\nSegundo punto")
    }

    @Test func readsTablesRowByRowAndSkipsCodeAndOptions() {
        let text = """
        Estado:

        | Conversación | ¿Burbuja? |
        |---|---|
        | GasCorp | **Sí** |

        ```swift
        let x = 1
        ```
        <options>
        <option>Sí</option>
        </options>
        """
        #expect(SpokenText.from(markdown: text) == "Estado:\nConversación: GasCorp. ¿Burbuja?: Sí.")
    }

    @Test func readsInSentencesForSkipping() {
        let text = "## Resumen\nYa quedó listo. ¿Lo pruebas? Sí.\n\n- Primer punto"
        #expect(SpokenText.sentences(markdown: text) == ["Resumen", "Ya quedó listo.", "¿Lo pruebas?", "Sí.", "Primer punto"])
        #expect(SpokenText.sentences(markdown: "```\ncode\n```").isEmpty)
    }

    @Test func speedStepsUpAndDownWithinRange() {
        // Fine steps around the normal pace.
        #expect(SpeechRate.faster(1) == 1.1)
        #expect(SpeechRate.faster(1.1) == 1.2)
        #expect(SpeechRate.slower(1) == 0.9)
        #expect(SpeechRate.faster(SpeechRate.steps.last!) == SpeechRate.steps.last!)
        #expect(SpeechRate.slower(SpeechRate.steps.first!) == SpeechRate.steps.first!)
        // A stored value between steps moves to the neighbouring step.
        #expect(SpeechRate.faster(1.05) == 1.1)
        #expect(SpeechRate.slower(1.05) == 1)
        #expect(SpeechRate.label(1.1) == "1.1×")
        #expect(SpeechRate.label(2) == "2×")
    }
}
