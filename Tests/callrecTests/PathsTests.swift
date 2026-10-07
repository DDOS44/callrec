import Foundation
import Testing
@testable import CallrecCore

@Test func pathScheme() {
    var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 18; c.hour = 9; c.minute = 5; c.second = 7
    guard let d = Calendar.current.date(from: c) else { Issue.record("paths: bad date"); return }
    let p = Paths.forCall(at: d, root: URL(fileURLWithPath: "/tmp/cr"))
    equal(p.dir.path, "/tmp/cr/2026-09-18", "paths.dir")
    equal(p.m4a.lastPathComponent, "09-05-07.m4a", "paths.m4a")
    equal(p.md.lastPathComponent, "09-05-07.md", "paths.md")
    equal(p.farWav.lastPathComponent, "09-05-07.far.wav", "paths.farWav")
    equal(p.micWav.lastPathComponent, "09-05-07.mic.wav", "paths.micWav")
    equal(p.mixWav.lastPathComponent, "09-05-07.mix.wav", "paths.mixWav")
}
