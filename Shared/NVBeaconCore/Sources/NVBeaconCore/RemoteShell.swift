import Foundation

/// SSH hands a command to the user's login shell, which may be zsh, tcsh or fish.
/// Our scripts are POSIX sh, so they must reach `/bin/sh` unchanged.
public enum RemoteShell {
    /// csh/tcsh reject newlines inside single quotes and expand `!` there, and fish
    /// treats `\\` and `\'` there as escapes. A script containing any of those
    /// characters is therefore sent on one line as `printf %b` octal escapes, which
    /// every login shell leaves intact. The result is still a `/bin/sh` script.
    public static func portable(_ script: String) -> String {
        let escapes: [Unicode.Scalar: String] = ["\\": "\\0134", "\n": "\\0012", "\r": "\\0015", "'": "\\0047", "!": "\\0041"]
        guard script.unicodeScalars.contains(where: { escapes[$0] != nil }) else { return script }
        var encoded = ""
        for scalar in script.unicodeScalars {
            if let escape = escapes[scalar] { encoded += escape } else { encoded.unicodeScalars.append(scalar) }
        }
        return "exec /bin/sh -c \"$(printf '%b' '\(encoded)')\""
    }

    /// A command string for an SSH exec request that runs `script` in `/bin/sh`
    /// whatever the login shell is. The login shell only sees one single-quoted word.
    public static func shCommand(_ script: String) -> String {
        "/bin/sh -c " + quoted(portable(script))
    }

    /// Quotes with '"'"' rather than '\'' so the result contains no backslashes.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
