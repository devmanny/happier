import Testing
@testable import HappierKit

@Suite struct FileMentionTests {
    @Test func plainPathsAreBareTokens() {
        #expect(FileMention.token("src/README.md") == "@src/README.md")
    }

    @Test func boundaryCharactersQuoteThePathAndDoubleInnerQuotes() {
        #expect(FileMention.token("My Docs/notes (1).md") == "@\"My Docs/notes (1).md\"")
        #expect(FileMention.token("say \"hi\".txt") == "@\"say \"\"hi\"\".txt\"")
    }

    @Test func appendsWithOneSeparatingSpaceAndATrailingOne() {
        #expect(FileMention.appending("a.swift", to: "") == "@a.swift ")
        #expect(FileMention.appending("a.swift", to: "look at") == "look at @a.swift ")
        #expect(FileMention.appending("a.swift", to: "look at ") == "look at @a.swift ")
        #expect(FileMention.appending("a.swift", to: "first\n") == "first\n@a.swift ")
    }

    @Test func ripgrepOutputBecomesRelativePaths() {
        let stdout = "./src/app.ts\nREADME.md\r\n\nsrc/lib/util.ts\n"
        #expect(FileMention.files(fromRipgrep: stdout) == ["src/app.ts", "README.md", "src/lib/util.ts"])
    }

    @Test func searchPrefersFileNameMatchesThenShorterPaths() {
        let files = ["docs/guide/composer-notes.md", "Sources/Composer.swift", "Tests/ComposerTests.swift", "composer/index.ts", "README.md"]
        let hits = FileMention.search(files, query: "composer", limit: 10)
        #expect(hits.first == "Sources/Composer.swift")
        #expect(!hits.contains("README.md"))
        #expect(hits.last == "composer/index.ts")
        #expect(FileMention.search(files, query: "COMPOSER swift", limit: 10) == ["Sources/Composer.swift", "Tests/ComposerTests.swift"])
        #expect(FileMention.search(files, query: "", limit: 2).count == 2)
    }

    /// The `@` index holds the folders above the files too, so a folder can be mentioned
    /// (`buildFileItemsFromPaths` in `suggestionFile.ts`).
    @Test func indexAddsTheFoldersAboveItsFiles() {
        let index = FileMention.index(fromRipgrep: "src/lib/util.ts\nsrc/app.ts\nREADME.md\n")
        #expect(index == ["src/lib/util.ts", "src/app.ts", "README.md", "src/", "src/lib/"])
        #expect(FileMention.search(index, query: "lib", limit: 3).first == "src/lib/")
    }

    @Test func searchToleratesSkippedLetters() {
        let files = ["Sources/Composer.swift", "README.md", "Package.swift"]
        #expect(FileMention.search(files, query: "cmpsr", limit: 5) == ["Sources/Composer.swift"])
        #expect(FileMention.search(files, query: "zzz", limit: 5).isEmpty)
    }

    /// A name the index doesn't hold is looked up on the machine with a case-insensitive glob;
    /// glob syntax in what was typed is matched literally.
    @Test func nameGlobMatchesWhatWasTypedLiterally() {
        #expect(FileMention.nameGlob("composer") == "*composer*")
        #expect(FileMention.nameGlob(" my  notes[1]?.md ") == "*my*notes\\[1\\]\\?.md*")
    }

    @Test func listingKeepsFilesAndFolders() throws {
        let response: JSONValue = ["ok": true, "entries": [
            ["name": "b.txt", "path": "/p/b.txt", "type": "file"],
            ["name": "src", "path": "/p/src", "type": "directory"],
            ["name": ".env", "path": "/p/.env", "type": "file"],
            ["name": "a.md", "path": "/p/a.md", "type": "file"],
            ["name": "link", "path": "/p/link", "type": "other"],
        ]]
        let entries = try RemoteFolder.entries(from: response)
        #expect(entries.map(\.name) == ["src", "a.md", "b.txt", ".env"])
        #expect(entries.map(\.isDirectory) == [true, false, false, false])
    }
}
