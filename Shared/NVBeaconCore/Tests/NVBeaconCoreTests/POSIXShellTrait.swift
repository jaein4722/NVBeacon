import Testing

#if os(Windows)
private let hasPOSIXShell = false
#else
private let hasPOSIXShell = true
#endif

extension Trait where Self == ConditionTrait {
    /// Marks tests whose fake transport runs commands through a local `/bin/sh`.
    /// Windows has no `/bin/sh`, so these tests are skipped there rather than
    /// run against a substitute shell that does not behave like the remote Linux host.
    static var requiresPOSIXShell: Self {
        .enabled(if: hasPOSIXShell, "Requires a local POSIX /bin/sh, which Windows does not provide")
    }
}
