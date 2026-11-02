import Foundation

public enum SSHAuthenticationMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case keyBased
    case passwordBased
    public var id: String { rawValue }
}

public enum SSHConnectionReuseMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case reuseWhenPossible
    case newConnectionEachRefresh
    public var id: String { rawValue }
}
