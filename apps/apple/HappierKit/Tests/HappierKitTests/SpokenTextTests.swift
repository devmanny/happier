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
}
