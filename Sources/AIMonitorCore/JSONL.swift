import Foundation

/// Streaming JSONL reader.
///
/// Log files here reach tens of thousands of lines; this reads in chunks and
/// compacts the buffer once per chunk rather than once per line.
public enum JSONL {
    public static func forEachObject(
        at url: URL,
        _ body: ([String: Any]) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var buffer = Data()
        let chunkSize = 1 << 20
        let newline: UInt8 = 0x0A

        func drain(final: Bool) throws {
            var searchFrom = buffer.startIndex
            while let idx = buffer[searchFrom...].firstIndex(of: newline) {
                let line = buffer[searchFrom..<idx]
                if !line.isEmpty, let obj = decode(Data(line)) { try body(obj) }
                searchFrom = buffer.index(after: idx)
            }
            if searchFrom > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<searchFrom)
            }
            if final, !buffer.isEmpty, let obj = decode(buffer) {
                try body(obj)
                buffer.removeAll(keepingCapacity: false)
            }
        }

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            try drain(final: false)
        }
        try drain(final: true)
    }

    /// A malformed line is skipped, not fatal. Logs get truncated mid-write when
    /// a tool exits, and one bad tail line should not void an entire session.
    private static func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Tolerant accessors. The logs are someone else's format and will drift; these
/// read defensively rather than binding to a generated schema that would throw
/// on an added field.
extension Dictionary where Key == String, Value == Any {
    public func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }

    public func int(_ key: String) -> Int? {
        if let i = self[key] as? Int { return i }
        if let d = self[key] as? Double { return Int(d) }
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }

    public func double(_ key: String) -> Double? {
        if let d = self[key] as? Double { return d }
        if let i = self[key] as? Int { return Double(i) }
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }

    public func str(_ key: String) -> String? { self[key] as? String }

    public func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let n = self[key] as? NSNumber { return n.boolValue }
        return nil
    }
}

public enum Timestamps {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Both log formats write RFC3339 with a `Z` suffix; fractional seconds are
    /// present in Codex and may or may not be in Claude Code.
    public static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return withFraction.date(from: value) ?? plain.date(from: value)
    }
}
