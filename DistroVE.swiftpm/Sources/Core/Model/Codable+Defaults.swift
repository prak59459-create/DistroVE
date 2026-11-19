import Foundation

extension KeyedDecodingContainer {
    /// キーが無い・壊れているときは既定値を使う（古い .disve や一部が壊れたファイルでも開けるようにする）。
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        if let decoded = try? decodeIfPresent(T.self, forKey: key) {
            return decoded
        }
        return fallback
    }

    func optional<T: Decodable>(_ key: Key, _ type: T.Type) -> T? {
        if let decoded = try? decodeIfPresent(type, forKey: key) {
            return decoded
        }
        return nil
    }
}
