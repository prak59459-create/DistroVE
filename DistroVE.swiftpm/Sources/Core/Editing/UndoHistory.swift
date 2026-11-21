import Foundation

/// 元に戻す・やり直し（Q38: 回数無制限）。
/// 直近の履歴はメモリに置き、古いものは JSON にしてディスクへ逃がすので、回数を制限せずにメモリを抑えられる。
final class UndoHistory {
    struct Entry {
        let name: String
        let state: Project
        let coalesceKey: String?
        let date: Date
    }

    private struct Stored: Codable {
        let name: String
        let state: Project
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var undoSpilled: [URL] = []
    private var redoSpilled: [URL] = []
    private let spillDirectory: URL?
    private let memoryLimit: Int
    private var sequence: Int = 0

    /// spillDirectory が nil ならメモリだけで持つ（テスト用）。
    init(spillDirectory: URL?, memoryLimit: Int = 80) {
        self.spillDirectory = spillDirectory
        self.memoryLimit = max(2, memoryLimit)
        if let dir = spillDirectory {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    deinit {
        if let dir = spillDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    var canUndo: Bool { return !undoStack.isEmpty || !undoSpilled.isEmpty }
    var canRedo: Bool { return !redoStack.isEmpty || !redoSpilled.isEmpty }
    var undoName: String? { return undoStack.last?.name }
    var redoName: String? { return redoStack.last?.name }
    var count: Int { return undoStack.count + undoSpilled.count }

    /// 変更の前の状態を記録する。coalesceKey が直前と同じで 1.5 秒以内なら 1 回分にまとめる（スライダー操作など）。
    func record(before state: Project, name: String, coalesceKey: String? = nil) {
        if let key = coalesceKey, let last = undoStack.last, last.coalesceKey == key, Date().timeIntervalSince(last.date) < 1.5 {
            undoStack[undoStack.count - 1] = Entry(name: last.name, state: last.state, coalesceKey: key, date: Date())
            clearRedo()
            return
        }
        undoStack.append(Entry(name: name, state: state, coalesceKey: coalesceKey, date: Date()))
        clearRedo()
        spillIfNeeded(&undoStack, &undoSpilled)
    }

    /// 1 つ前に戻す。current は今の状態（やり直し用に積む）。
    func undo(current: Project) -> Project? {
        guard let entry = pop(&undoStack, &undoSpilled) else { return nil }
        redoStack.append(Entry(name: entry.name, state: current, coalesceKey: nil, date: Date()))
        spillIfNeeded(&redoStack, &redoSpilled)
        return entry.state
    }

    func redo(current: Project) -> Project? {
        guard let entry = pop(&redoStack, &redoSpilled) else { return nil }
        undoStack.append(Entry(name: entry.name, state: current, coalesceKey: nil, date: Date()))
        spillIfNeeded(&undoStack, &undoSpilled)
        return entry.state
    }

    func clear() {
        undoStack.removeAll()
        clearRedo()
        for url in undoSpilled { try? FileManager.default.removeItem(at: url) }
        undoSpilled.removeAll()
    }

    private func clearRedo() {
        redoStack.removeAll()
        for url in redoSpilled { try? FileManager.default.removeItem(at: url) }
        redoSpilled.removeAll()
    }

    private func spillIfNeeded(_ stack: inout [Entry], _ spilled: inout [URL]) {
        guard let dir = spillDirectory else {
            // ディスクが無いときは古いものから捨てる
            if stack.count > memoryLimit * 4 { stack.removeFirst(stack.count - memoryLimit * 4) }
            return
        }
        while stack.count > memoryLimit {
            let oldest: Entry = stack.removeFirst()
            sequence += 1
            let url: URL = dir.appendingPathComponent("\(sequence).json")
            do {
                let data: Data = try JSONEncoder().encode(Stored(name: oldest.name, state: oldest.state))
                try data.write(to: url)
                spilled.append(url)
            } catch {
                // 書けなければその履歴はあきらめる
            }
        }
    }

    private func pop(_ stack: inout [Entry], _ spilled: inout [URL]) -> Entry? {
        if let entry = stack.popLast() {
            return entry
        }
        guard let url = spilled.popLast() else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
        }
        return Entry(name: stored.name, state: stored.state, coalesceKey: nil, date: Date())
    }
}
