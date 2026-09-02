/// The tool's own version, compiled in.
///
/// It cannot be read from the `VERSION` file at run time: the installed
/// binary is a copy in `~/.local/bin`, and the only path it could derive is
/// `#filePath` — the source tree it was built from, which may have moved,
/// changed or been bumped since. So the constant is the truth in the binary
/// and `VERSION` is the truth in the repo, and one test asserts they agree.
public let otaVersion = "0.1.0"
