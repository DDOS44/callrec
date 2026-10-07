import Foundation
import CallrecCore

/// Thin smoke check for an installed binary: proves the build wiring works
/// (Core links, Markdown round-trips, paths resolve). The real checks live in
/// Tests/callrecTests and run with scripts/test.sh.
enum SelfTest {
    static func runAll() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) { if !ok { failures.append("FAIL \(name)") } }

        let segments = [Segment(start: 1, end: 3, text: "haan ji", speaker: .me),
                        Segment(start: 3, end: 5, text: "boliye", speaker: .them)]
        let md = Markdown.render(date: Date(), seconds: 5, audioName: "x.m4a", segments: segments)
        check(md.contains("haan ji") && md.contains("boliye"), "markdown renders segments")
        check(MarkdownFields.error(md: md) == nil, "clean transcript has no error line")
        check(MarkdownFields.error(md: MarkdownFields.setError(md: md, message: "boom")) == "boom", "error marker round-trips")

        let p = Paths.forCall(at: Date(timeIntervalSince1970: 0), root: URL(fileURLWithPath: "/tmp/cr"))
        check(p.md.pathExtension == "md" && p.m4a.pathExtension == "m4a", "paths resolve")
        check(Announcements.isOperator("this call may be spam"), "operator announcement detected")
        return failures
    }
}
