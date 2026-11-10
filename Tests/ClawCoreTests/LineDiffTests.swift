import Foundation
import Testing

@testable import ClawCore

@Suite("Line diff and redacted change view")
struct LineDiffTests {
    @Test("Identical texts have no diff")
    func same() {
        #expect(LineDiff.unified(old: "a\nb\n", new: "a\nb\n").isEmpty)
    }

    @Test("A changed line shows as minus and plus with context")
    func changed() {
        let diff = LineDiff.unified(old: "a\nb\nc\nd\ne\n", new: "a\nb\nX\nd\ne\n", context: 1)
        #expect(diff == ["  b", "- c", "+ X", "  d"])
    }

    @Test("Added and removed lines, a new file has only plus lines")
    func addRemove() {
        #expect(LineDiff.unified(old: "", new: "x\ny\n") == ["+ x", "+ y"])
        #expect(LineDiff.unified(old: "x\ny\n", new: "") == ["- x", "- y"])
        #expect(LineDiff.unified(old: "a\nb\n", new: "a\nb\nc\n", context: 0) == ["+ c"])
    }

    @Test("Far apart changes are separated by a gap marker")
    func gap() {
        let old = (1...20).map(String.init).joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "\n2\n", with: "\ntwo\n").replacingOccurrences(of: "\n19\n", with: "\nnineteen\n")
        let diff = LineDiff.unified(old: old, new: new, context: 1)
        #expect(diff.contains("  ⋯"))
        #expect(diff.contains("- 2") && diff.contains("+ two") && diff.contains("- 19") && diff.contains("+ nineteen"))
        #expect(!diff.contains("  10"))
    }

    @Test("JSON is shown with secret values masked, on both sides")
    func redacted() throws {
        let before = Data(#"{"mcpServers":{"s":{"command":"x","env":{"API_KEY":"sk-live-123"}}}}"#.utf8)
        let after = Data(#"{"mcpServers":{}}"#.utf8)
        let text = ChangeView.lines(file: "/h/.claude.json", before: before, after: after).joined(separator: "\n")
        #expect(!text.contains("sk-live-123"))
        #expect(text.contains("- ") && text.contains("API_KEY"))
    }

    @Test("A file that is not JSON shows sizes only, never its content")
    func notJSON() {
        let lines = ChangeView.lines(file: "/h/x.md", before: Data("secret body".utf8), after: Data("other".utf8))
        #expect(lines == ["  (not JSON: 11 bytes → 5 bytes, content not shown)"])
    }

    @Test("A new file has no before")
    func newFile() {
        let lines = ChangeView.lines(file: "/h/a.json", before: nil, after: Data(#"{"a":1}"#.utf8))
        #expect(lines.first == "+ {")
    }
}
