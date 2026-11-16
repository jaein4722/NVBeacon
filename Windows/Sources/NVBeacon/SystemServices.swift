import Foundation
import NVBeaconWindowsKit
import WinSDK

/// Launch at login through the per-user Run key (no elevation needed).
enum LaunchAtLogin {
    private static let key = #"Software\Microsoft\Windows\CurrentVersion\Run"#
    private static let valueName = "NVBeacon"

    enum Status: String { case enabled, disabled, otherLocation }

    private static var command: String { "\"\(Resources.executablePath)\"" }

    static var status: Status {
        guard let current = registeredCommand else { return .disabled }
        return current.caseInsensitiveCompare(command) == .orderedSame ? .enabled : .otherLocation
    }

    private static var registeredCommand: String? {
        var size: DWORD = 0
        let probe = key.withCString(encodedAs: UTF16.self) { key in
            valueName.withCString(encodedAs: UTF16.self) { name in
                RegGetValueW(HKEY_CURRENT_USER, key, name, DWORD(RRF_RT_REG_SZ), nil, nil, &size)
            }
        }
        guard probe == ERROR_SUCCESS, size > 0 else { return nil }
        var buffer = [WCHAR](repeating: 0, count: Int(size) / 2 + 1)
        let status = key.withCString(encodedAs: UTF16.self) { key in
            valueName.withCString(encodedAs: UTF16.self) { name in
                RegGetValueW(HKEY_CURRENT_USER, key, name, DWORD(RRF_RT_REG_SZ), nil, &buffer, &size)
            }
        }
        guard status == ERROR_SUCCESS else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }

    /// Returns an error message, or nil on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        var handle: HKEY?
        let opened = key.withCString(encodedAs: UTF16.self) {
            RegCreateKeyExW(HKEY_CURRENT_USER, $0, 0, nil, 0, REGSAM(KEY_SET_VALUE), nil, &handle, nil)
        }
        guard opened == ERROR_SUCCESS, let handle else { return "Could not open the Run key (error \(opened))." }
        defer { RegCloseKey(handle) }
        let result: LSTATUS
        if enabled {
            let data = Array(command.utf16) + [0]
            result = valueName.withCString(encodedAs: UTF16.self) { name in
                data.withUnsafeBytes { bytes in
                    RegSetValueExW(handle, name, 0, DWORD(REG_SZ), bytes.baseAddress?.assumingMemoryBound(to: BYTE.self), DWORD(bytes.count))
                }
            }
        } else {
            result = valueName.withCString(encodedAs: UTF16.self) { RegDeleteValueW(handle, $0) }
            if result == ERROR_FILE_NOT_FOUND { return nil }
        }
        return result == ERROR_SUCCESS ? nil : "Could not update the Run key (error \(result))."
    }
}

/// Common file dialogs (comdlg32).
enum FileDialog {
    /// `filter` is pairs like [("JSON", "*.json")].
    static func open(owner: HWND?, title: String, filter: [(String, String)], initialFolder: String? = nil) -> String? {
        run(owner: owner, title: title, filter: filter, fileName: "", initialFolder: initialFolder, save: false)
    }

    static func save(owner: HWND?, title: String, filter: [(String, String)], fileName: String, defaultExtension: String) -> String? {
        run(owner: owner, title: title, filter: filter, fileName: fileName, initialFolder: nil, save: true, defaultExtension: defaultExtension)
    }

    private static func run(owner: HWND?, title: String, filter: [(String, String)], fileName: String,
                            initialFolder: String?, save: Bool, defaultExtension: String = "") -> String? {
        var filterText = Array(filter.flatMap { [$0.0, $0.1] }.joined(separator: "\0").utf16) + [0, 0]
        var buffer = [WCHAR](repeating: 0, count: 4096)
        for (index, unit) in fileName.utf16.prefix(4000).enumerated() { buffer[index] = unit }
        var titleText = Array(title.utf16) + [0]
        var extensionText = Array(defaultExtension.utf16) + [0]
        var folderText = Array((initialFolder ?? "").utf16) + [0]
        var dialog = OPENFILENAMEW()
        dialog.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
        dialog.hwndOwner = owner
        dialog.nMaxFile = DWORD(buffer.count)
        let ok: Bool = filterText.withUnsafeMutableBufferPointer { filterPointer in
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                titleText.withUnsafeMutableBufferPointer { titlePointer in
                    extensionText.withUnsafeMutableBufferPointer { extensionPointer in
                        folderText.withUnsafeMutableBufferPointer { folderPointer in
                            dialog.lpstrFilter = UnsafePointer(filterPointer.baseAddress)
                            dialog.lpstrFile = bufferPointer.baseAddress
                            dialog.lpstrTitle = UnsafePointer(titlePointer.baseAddress)
                            if !defaultExtension.isEmpty { dialog.lpstrDefExt = UnsafePointer(extensionPointer.baseAddress) }
                            if initialFolder != nil { dialog.lpstrInitialDir = UnsafePointer(folderPointer.baseAddress) }
                            if save {
                                dialog.Flags = DWORD(OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR)
                                return GetSaveFileNameW(&dialog)
                            }
                            dialog.Flags = DWORD(OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR)
                            return GetOpenFileNameW(&dialog)
                        }
                    }
                }
            }
        }
        return ok ? String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self) : nil
    }
}

enum Shell {
    static func copyToClipboard(_ text: String, owner: HWND?) {
        let units = Array(text.utf16) + [0]
        guard OpenClipboard(owner) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        let bytes = units.count * MemoryLayout<UInt16>.size
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes)) else { return }
        guard let pointer = GlobalLock(memory) else {
            GlobalFree(memory)
            return
        }
        units.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        GlobalUnlock(memory)
        if SetClipboardData(UINT(CF_UNICODETEXT), memory) == nil { GlobalFree(memory) }
    }

    /// Opens only the project's own pages; anything else from a page is ignored.
    static func openWebPage(_ url: String) {
        let allowed = ["https://github.com/jaein4722/NVBeacon", "https://github.com/jaein4722"]
        guard allowed.contains(url) else { return }
        _ = url.withCString(encodedAs: UTF16.self) { ShellExecuteW(nil, nil, $0, nil, nil, SW_SHOWNORMAL) }
    }

    static func openInNotepad(_ path: String) {
        "notepad.exe".withCString(encodedAs: UTF16.self) { program in
            WindowsCommandLine.quote(path).withCString(encodedAs: UTF16.self) { argument in
                _ = ShellExecuteW(nil, nil, program, argument, nil, SW_SHOWNORMAL)
            }
        }
    }
}
