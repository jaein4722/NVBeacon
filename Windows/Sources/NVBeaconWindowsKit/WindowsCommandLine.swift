/// Builds a `CreateProcessW` command line that the Microsoft C runtime splits
/// back into exactly the given arguments.
public enum WindowsCommandLine {
    public static func build(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(quote).joined(separator: " ")
    }

    /// Quotes one argument using the MSVCRT parsing rules: backslashes are literal
    /// unless they precede a double quote, so those runs are doubled.
    public static func quote(_ argument: String) -> String {
        guard argument.isEmpty || argument.contains(where: { " \t\n\u{0B}\"".contains($0) }) else {
            return argument
        }
        var result = "\""
        var backslashes = 0
        for character in argument {
            if character == "\\" {
                backslashes += 1
                continue
            }
            if character == "\"" {
                result += String(repeating: "\\", count: backslashes * 2 + 1)
                result.append("\"")
            } else {
                result += String(repeating: "\\", count: backslashes)
                result.append(character)
            }
            backslashes = 0
        }
        result += String(repeating: "\\", count: backslashes * 2)
        result.append("\"")
        return result
    }
}
