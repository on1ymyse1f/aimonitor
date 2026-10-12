import XCTest
@testable import AIMonitorCore

final class JSONLTests: XCTestCase {
    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func testIncompleteTailResumesWhenNeedleArrivesLater() throws {
        let dir = TempDir()
        let prefix = "{\"message\":\"中文\"}\nmalformed\n\n"
        let file = dir.write([prefix + "{\"us"], to: "log.jsonl")
        var values: [Int] = []
        let checkpoint = try JSONL.forEachLine(at: file, from: 0, needles: ["\"usage\""]) { object, _, _ in
            values.append(object.int("usage")!)
        }
        XCTAssertEqual(checkpoint, UInt64(prefix.utf8.count))
        XCTAssertTrue(values.isEmpty)

        try append(Data("age\":7}\n".utf8), to: file)
        let end = try JSONL.forEachLine(at: file, from: checkpoint, needles: ["\"usage\""]) { object, start, end in
            XCTAssertEqual(start, UInt64(prefix.utf8.count))
            XCTAssertEqual(end, UInt64(prefix.utf8.count + "{\"usage\":7}\n".utf8.count))
            values.append(object.int("usage")!)
        }
        XCTAssertEqual(values, [7])
        XCTAssertEqual(end, UInt64(try Data(contentsOf: file).count))
    }

    func testPartialUTF8TailAcrossChunkBoundary() throws {
        let dir = TempDir()
        let record = Data(("{\"text\":\"" + String(repeating: "a", count: 1 << 20) + "中\",\"usage\":9}").utf8)
        let marker = try XCTUnwrap(record.range(of: Data("中".utf8)))
        let split = marker.lowerBound + 1 // EOF in the middle of a UTF-8 scalar.
        let file = dir.url.appendingPathComponent("log.jsonl")
        try record.prefix(split).write(to: file)
        var count = 0
        let checkpoint = try JSONL.forEachLine(at: file, from: 0) { _, _, _ in count += 1 }
        XCTAssertEqual(checkpoint, 0)
        XCTAssertEqual(count, 0)
        try append(Data(record.dropFirst(split)), to: file)
        let end = try JSONL.forEachLine(at: file, from: checkpoint) { object, start, _ in
            XCTAssertEqual(start, 0)
            XCTAssertEqual(object.int("usage"), 9)
            count += 1
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(end, UInt64(record.count))
    }

    func testCompleteTailIsConsumedWithOrWithoutNeedleMatch() throws {
        let dir = TempDir()
        let file = dir.write(["{\"usage\":7}"], to: "log.jsonl")
        for needles in [[], ["\"usage\""], ["absent"]] {
            var count = 0
            let end = try JSONL.forEachLine(at: file, from: 0, needles: needles) { _, _, _ in count += 1 }
            XCTAssertEqual(end, UInt64(try Data(contentsOf: file).count))
            XCTAssertEqual(count, needles == ["absent"] ? 0 : 1)
        }
        // A newline appended after a complete object must not replay that object.
        let checkpoint = UInt64(try Data(contentsOf: file).count)
        try append(Data("\n{\"usage\":8}\n".utf8), to: file)
        var values: [Int] = []
        _ = try JSONL.forEachLine(at: file, from: checkpoint) { object, _, _ in values.append(object.int("usage")!) }
        XCTAssertEqual(values, [8])
    }
}
