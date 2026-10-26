import Foundation

#if !canImport(ObjectiveC)
/// Linux and Windows have no Objective-C runtime, so nothing is autoreleased:
/// ARC frees on the spot and a pool boundary is just the closure.
@inline(__always)
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

/// Path handling that does not depend on which OS wrote or reads a path.
enum PathParts {
    /// Last component of a path a tool recorded *inside* its log (Codex `cwd`,
    /// Kimi `workDir`). The tool may have run on Windows, so either separator
    /// can appear whatever platform is reading the log.
    static func last(of path: String) -> String? {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
    }

    /// First component of `file` below `root`: the per-project directory of
    /// Claude Code and Kimi Code. Compares components, not strings, so it
    /// holds whichever separator `URL.path` uses on this platform.
    ///
    /// Both sides are symlink-resolved first: a directory enumerator may hand
    /// back resolved paths for an unresolved root (macOS turns `/var/…` into
    /// `/private/var/…`; a symlinked `~/.claude` does the same).
    static func first(of file: URL, under root: URL) -> String? {
        for (f, r) in [(file, root), (file.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())] {
            let fileParts = f.pathComponents, rootParts = r.pathComponents
            if fileParts.count > rootParts.count, fileParts.starts(with: rootParts) {
                return fileParts[rootParts.count]
            }
        }
        return nil
    }
}
