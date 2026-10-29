import Foundation
import Testing
@testable import CallrecCore

// Regression (2026-10-29): importing the same sheet again created MASTER-CALL-LIST-3 next to
// MASTER-CALL-LIST-2 with empty progress, so every lead looked uncalled.

private func dir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("lists-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Test func reimportingTheSameFileReusesTheCopyWithTheLatestProgress() throws {
    let lists = try dir(), outside = try dir()
    defer { Fs.remove(lists); Fs.remove(outside) }
    let body = Data("company,phone\nFake One,9000000001\n".utf8)
    for name in ["LIST.csv", "LIST-2.csv", "LIST-3.csv"] { try body.write(to: lists.appendingPathComponent(name)) }
    try Data("other,phone\n".utf8).write(to: lists.appendingPathComponent("OTHER.csv"))
    try Data("{}".utf8).write(to: lists.appendingPathComponent("LIST.state.json"))
    try Data("{}".utf8).write(to: lists.appendingPathComponent("LIST-2.state.json"))
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                          ofItemAtPath: lists.appendingPathComponent("LIST.state.json").path)
    let source = outside.appendingPathComponent("LIST.csv")
    try body.write(to: source)
    #expect(ListCopies.existingCopy(of: source, in: lists)?.lastPathComponent == "LIST-2.csv",
            "the copy with the newest progress file")
}

@Test func aChangedFileIsNotMistakenForAnOldCopy() throws {
    let lists = try dir(), outside = try dir()
    defer { Fs.remove(lists); Fs.remove(outside) }
    try Data("company,phone\nFake One,9000000001\n".utf8).write(to: lists.appendingPathComponent("LIST.csv"))
    let source = outside.appendingPathComponent("LIST.csv")
    try Data("company,phone\nFake One,9000000001\nFake Two,9000000002\n".utf8).write(to: source)
    #expect(ListCopies.existingCopy(of: source, in: lists) == nil)
}
