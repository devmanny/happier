import Testing
@testable import HappierKit

/// Line diffs for tool cards: computed from an edit's old and new text, or read from a unified diff.
@Suite struct TextDiffTests {
    @Test func anEditShowsRemovedThenAddedLinesWithContext() {
        let diff = TextDiff(old: "a\nb\nc\nd\ne\nf\ng\nh", new: "a\nb\nc\nD\ne\nf\ng\nh", context: 2)
        #expect(diff.lines.map(\.kind) == [.context, .context, .removed, .added, .context, .context])
        #expect(diff.lines.map(\.text) == ["b", "c", "d", "D", "e", "f"])
        #expect(diff.lines[2].oldNumber == 4 && diff.lines[2].newNumber == nil)
        #expect(diff.lines[3].newNumber == 4 && diff.lines[3].oldNumber == nil)
        #expect(diff.added == 1 && diff.removed == 1)
    }

    @Test func farApartChangesBecomeSeparateHunks() {
        let old = (1...20).map(String.init).joined(separator: "\n")
        let new = (1...20).map { $0 == 2 ? "two" : $0 == 19 ? "nineteen" : String($0) }.joined(separator: "\n")
        let diff = TextDiff(old: old, new: new, context: 1)
        #expect(diff.lines.contains { $0.kind == .gap })
        #expect(diff.added == 2 && diff.removed == 2)
    }

    @Test func aNewFileIsAllAdded() {
        let diff = TextDiff(old: "", new: "x\ny")
        #expect(diff.lines.map(\.kind) == [.added, .added] && diff.removed == 0)
    }

    @Test func readsAUnifiedDiffPerFile() {
        let text = """
        diff --git a/src/a.swift b/src/a.swift
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -1,3 +1,3 @@
         let x = 1
        -let y = 2
        +let y = 3
         let z = 4
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hello
        """
        let files = TextDiff.files(fromUnified: text)
        #expect(files.map(\.path) == ["src/a.swift", "new.txt"])
        #expect(files[0].diff.lines.map(\.kind) == [.hunk, .context, .removed, .added, .context])
        #expect(files[0].diff.lines[2].oldNumber == 2 && files[0].diff.lines[3].newNumber == 2)
        #expect(files[1].diff.added == 1 && files[1].diff.removed == 0)
    }

    @Test func aBareHunkWithoutHeadersStillReads() {
        let files = TextDiff.files(fromUnified: "@@ -1 +1 @@\n-a\n+b")
        #expect(files.count == 1 && files[0].path == nil && files[0].diff.added == 1)
    }

    @Test func applyPatchEnvelopesReadPerFile() {
        let patch = """
        *** Begin Patch
        *** Update File: src/app.ts
        @@ function main
        -  old()
        +  next()
        *** Add File: notes.md
        +# Notes
        *** Delete File: gone.txt
        *** End Patch
        """
        let files = TextDiff.files(fromApplyPatch: patch)
        #expect(files.map(\.path) == ["src/app.ts", "notes.md", "gone.txt"])
        #expect(files[0].diff.added == 1 && files[0].diff.removed == 1)
        #expect(files[1].diff.added == 1)
        #expect(files[2].isDeletion)
    }
}
