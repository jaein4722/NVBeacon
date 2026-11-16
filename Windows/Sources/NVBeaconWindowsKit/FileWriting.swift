import Foundation

extension Data {
    /// Writes atomically (temp file, then rename), retrying briefly when Windows
    /// reports a sharing violation, which happens when antivirus or indexing opens
    /// the freshly written temp file at the moment of the rename. Falls back to a
    /// plain write so the data is not lost.
    func writeReliably(to url: URL) throws {
        var lastError: Error?
        for attempt in 0..<4 {
            do {
                try write(to: url, options: .atomic)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05 * Double(attempt + 1))
            }
        }
        do {
            try write(to: url)
        } catch {
            throw lastError ?? error
        }
    }
}
