import Foundation

/// キーフレーム間の補間方法。
enum Easing: String, Codable, CaseIterable, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case hold

    var label: String {
        switch self {
        case .linear: return "リニア"
        case .easeIn: return "イーズイン"
        case .easeOut: return "イーズアウト"
        case .easeInOut: return "イーズイン・アウト"
        case .hold: return "停止（階段）"
        }
    }

    /// 0〜1 の進み具合を補間カーブに通す。
    func apply(_ p: Double) -> Double {
        let t: Double = Num.clamp(p, 0, 1)
        switch self {
        case .linear:
            return t
        case .easeIn:
            return t * t * t
        case .easeOut:
            let u: Double = 1 - t
            return 1 - u * u * u
        case .easeInOut:
            if t < 0.5 { return 4 * t * t * t }
            let u: Double = -2 * t + 2
            return 1 - u * u * u / 2
        case .hold:
            return 0
        }
    }
}

/// 1 つのキーフレーム。time はクリップ先頭からの時間。
struct ParamKey: Hashable, Codable, Sendable {
    var time: Time
    var value: Double
    var easing: Easing

    init(time: Time, value: Double, easing: Easing = .easeInOut) {
        self.time = time
        self.value = value
        self.easing = easing
    }
}

/// キーフレームを打てる数値パラメーター。キーが無ければ固定値。
/// ファイルではキーが無いとき数値 1 つだけを書き、容量を抑える。
struct Param: Hashable, Codable, Sendable {
    var value: Double
    var keys: [ParamKey]

    init(_ value: Double) {
        self.value = value
        self.keys = []
    }

    init(value: Double, keys: [ParamKey]) {
        self.value = value
        self.keys = keys.sorted { $0.time < $1.time }
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case k
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let number = try? single.decode(Double.self) {
            value = number
            keys = []
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(Double.self, forKey: .v)
        keys = try container.decodeIfPresent([ParamKey].self, forKey: .k) ?? []
    }

    func encode(to encoder: Encoder) throws {
        if keys.isEmpty {
            var single = encoder.singleValueContainer()
            try single.encode(value)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .v)
        try container.encode(keys, forKey: .k)
    }

    var isAnimated: Bool { return !keys.isEmpty }

    /// クリップ内の時刻 t での値。
    func value(at t: Time) -> Double {
        if keys.isEmpty { return value }
        let first: ParamKey = keys[0]
        if t <= first.time { return first.value }
        let last: ParamKey = keys[keys.count - 1]
        if t >= last.time { return last.value }
        var low: Int = 0
        var high: Int = keys.count - 1
        while high - low > 1 {
            let mid: Int = (low + high) / 2
            if keys[mid].time <= t {
                low = mid
            } else {
                high = mid
            }
        }
        let a: ParamKey = keys[low]
        let b: ParamKey = keys[high]
        let span: Double = Double(b.time.ticks - a.time.ticks)
        if span <= 0 { return b.value }
        let p: Double = Double(t.ticks - a.time.ticks) / span
        return Num.lerp(a.value, b.value, a.easing.apply(p))
    }

    func keyIndex(near t: Time, tolerance: Time) -> Int? {
        var best: Int?
        var bestDistance: Int64 = tolerance.ticks + 1
        for (index, key) in keys.enumerated() {
            let distance: Int64 = abs(key.time.ticks - t.ticks)
            if distance <= tolerance.ticks && distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    func hasKey(at t: Time, tolerance: Time) -> Bool {
        return keyIndex(near: t, tolerance: tolerance) != nil
    }

    /// 値を設定する。キーフレームがあるときは時刻 t のキーを追加・更新する。
    mutating func set(_ newValue: Double, at t: Time, tolerance: Time) {
        if keys.isEmpty {
            value = newValue
            return
        }
        if let index = keyIndex(near: t, tolerance: tolerance) {
            keys[index].value = newValue
        } else {
            keys.append(ParamKey(time: t, value: newValue))
            keys.sort { $0.time < $1.time }
        }
    }

    /// 時刻 t にキーがあれば消し、無ければ現在の値でキーを打つ。
    mutating func toggleKey(at t: Time, tolerance: Time) {
        if let index = keyIndex(near: t, tolerance: tolerance) {
            let removed: ParamKey = keys.remove(at: index)
            if keys.isEmpty { value = removed.value }
            return
        }
        let current: Double = value(at: t)
        keys.append(ParamKey(time: t, value: current))
        keys.sort { $0.time < $1.time }
    }

    mutating func setEasing(_ easing: Easing, at t: Time, tolerance: Time) {
        if let index = keyIndex(near: t, tolerance: tolerance) {
            keys[index].easing = easing
        }
    }

    mutating func removeAllKeys() {
        if let first = keys.first { value = first.value }
        keys.removeAll()
    }

    /// クリップを分割したときに、前半・後半それぞれのパラメーターを作る（境目に補間値のキーを入れて動きを保つ）。
    func split(at t: Time) -> (Param, Param) {
        if keys.isEmpty { return (self, self) }
        let boundary: Double = value(at: t)
        var left: [ParamKey] = keys.filter { $0.time < t }
        left.append(ParamKey(time: t, value: boundary, easing: .linear))
        var right: [ParamKey] = [ParamKey(time: .zero, value: boundary, easing: .linear)]
        for key in keys where key.time > t {
            right.append(ParamKey(time: key.time - t, value: key.value, easing: key.easing))
        }
        return (Param(value: boundary, keys: left), Param(value: boundary, keys: right))
    }

    /// 先頭を d だけ詰めたとき（先頭トリム）にキーをずらす。
    func shifted(by delta: Time) -> Param {
        if keys.isEmpty { return self }
        var moved: [ParamKey] = []
        for key in keys {
            moved.append(ParamKey(time: key.time + delta, value: key.value, easing: key.easing))
        }
        return Param(value: value, keys: moved)
    }
}

/// パラメーターの範囲と表示名（インスペクターのスライダーを自動で作るための情報）。
struct ParamSpec: Sendable {
    let key: String
    let label: String
    let minValue: Double
    let maxValue: Double
    let defaultValue: Double
    let unit: String

    init(_ key: String, _ label: String, _ minValue: Double, _ maxValue: Double, _ defaultValue: Double, unit: String = "") {
        self.key = key
        self.label = label
        self.minValue = minValue
        self.maxValue = maxValue
        self.defaultValue = defaultValue
        self.unit = unit
    }
}

/// キー名で引けるパラメーターの集まり（色調整やエフェクトに使う。キーが無ければ既定値）。
struct ParamSet: Hashable, Codable, Sendable {
    var values: [String: Param]

    init() {
        values = [:]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = try container.decode([String: Param].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    func value(_ spec: ParamSpec, at t: Time) -> Double {
        guard let param = values[spec.key] else { return spec.defaultValue }
        return param.value(at: t)
    }

    func param(_ spec: ParamSpec) -> Param {
        return values[spec.key] ?? Param(spec.defaultValue)
    }

    mutating func set(_ spec: ParamSpec, _ param: Param) {
        values[spec.key] = param
    }

    func isDefault(_ spec: ParamSpec) -> Bool {
        guard let param = values[spec.key] else { return true }
        return !param.isAnimated && abs(param.value - spec.defaultValue) < 0.000001
    }

    var isAnimated: Bool {
        for (_, param) in values where param.isAnimated {
            return true
        }
        return false
    }

    func split(at t: Time) -> (ParamSet, ParamSet) {
        var left = ParamSet()
        var right = ParamSet()
        for (key, param) in values {
            let parts: (Param, Param) = param.split(at: t)
            left.values[key] = parts.0
            right.values[key] = parts.1
        }
        return (left, right)
    }

    func shifted(by delta: Time) -> ParamSet {
        var result = ParamSet()
        for (key, param) in values {
            result.values[key] = param.shifted(by: delta)
        }
        return result
    }
}
