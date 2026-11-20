import Testing
@testable import HappierKit

/// A reply streams in: every prefix must read exactly as a full parse of it would, while the work
/// per update stays with the lines that are new.
@Suite struct MarkdownStreamingTests {
    static let replies = [
        """
        ## Plan para el despliegue

        Primero revisé el relay y **no** encontré migraciones pendientes.

        1. Construir la imagen por digest
        2. Probar contra una copia de la base
           - health
           - API autenticada
        3. Desplegar con rollback listo

        - [x] Respaldo de la base
        - [ ] Verificar la app RN

        | Paso | Tiempo | Estado |
        |---|---:|---|
        | build | 4 min | ok |
        | smoke | 1 min | ok |

        ```swift
        let index = SearchIndex<String>()
        index.upsert("t1", fields: [])
        ```

        ---
        > Nota: el *rollback* queda en el HANDOFF.
        Listo.
        """,
        "Texto corrido sin formato que crece palabra por palabra hasta terminar en una frase larga sin saltos de línea.",
        "```\nsin cerrar\n- esto es código\n",
    ]

    @Test func everyStreamingPrefixReadsAsAFullParse() {
        for reply in Self.replies {
            var end = reply.startIndex
            while end < reply.endIndex {
                end = reply.index(end, offsetBy: 5, limitedBy: reply.endIndex) ?? reply.endIndex
                let prefix = String(reply[..<end])
                #expect(MarkdownProse.lines(prefix) == prefix.split(separator: "\n", omittingEmptySubsequences: false).map { MarkdownProse.line(String($0)) })
                #expect(MarkdownSegments.cached(prefix) == MarkdownSegments.parse(prefix))
            }
        }
    }

    @Test func aGrowingReplyParsesOnlyItsNewLines() {
        let base = (1...200).map { "- elemento número \($0) de una lista larga" }.joined(separator: "\n")
        let reader = MarkdownProse.LineReader()
        #expect(reader.lines(base) == MarkdownProse.lines(base))
        let before = reader.parsedLineCount
        #expect(reader.lines(base + "\n- uno más").last == .bullet(indent: 0, marker: "•", text: "uno más"))
        #expect(reader.parsedLineCount - before == 1)
    }
}
