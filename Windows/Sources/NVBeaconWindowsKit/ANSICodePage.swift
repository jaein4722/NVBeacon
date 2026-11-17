import WinSDK

enum ANSICodePage {
    /// Decodes bytes in the system ANSI code page (`CP_ACP`).
    static func decode(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        return bytes.withUnsafeBufferPointer { input in
            input.withMemoryRebound(to: CHAR.self) { chars in
                let count = MultiByteToWideChar(UINT(CP_ACP), 0, chars.baseAddress, Int32(chars.count), nil, 0)
                guard count > 0 else { return String(decoding: bytes, as: UTF8.self) }
                var wide = [WCHAR](repeating: 0, count: Int(count))
                MultiByteToWideChar(UINT(CP_ACP), 0, chars.baseAddress, Int32(chars.count), &wide, count)
                return String(decoding: wide, as: UTF16.self)
            }
        }
    }
}
