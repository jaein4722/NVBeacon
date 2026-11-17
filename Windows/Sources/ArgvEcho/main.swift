import Foundation

// Test helper: prints the arguments it received, as the C runtime split them.
let arguments = Array(CommandLine.arguments.dropFirst())
let data = try JSONSerialization.data(withJSONObject: arguments)
FileHandle.standardOutput.write(data)
