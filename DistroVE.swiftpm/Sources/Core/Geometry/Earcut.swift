import Foundation

/// 穴のある多角形を三角形に分ける（3D 文字の表と裏の面）。
/// mapbox/earcut（ISC ライセンス）の手順を Swift に移したもの。点は添字でつなぐ（参照の循環を作らない）。
enum Earcut {
    /// outer と holes は閉じた輪（最初の点を最後に繰り返さない）。戻り値の indices は points の添字 3 つずつ。
    static func triangulate(outer: [SIMD2<Double>], holes: [[SIMD2<Double>]]) -> (points: [SIMD2<Double>], indices: [Int]) {
        var points: [SIMD2<Double>] = outer
        var holeStarts: [Int] = []
        for hole in holes where hole.count >= 3 {
            holeStarts.append(points.count)
            points.append(contentsOf: hole)
        }
        let list = EarcutList(points: points)
        let outerEnd: Int = holeStarts.first ?? points.count
        guard let first = list.linkedList(start: 0, end: outerEnd, clockwise: true) else { return (points, []) }
        if list.next[first] == list.prev[first] { return (points, []) }
        var outerNode: Int = first
        if !holeStarts.isEmpty {
            outerNode = list.eliminateHoles(holeStarts: holeStarts, outerNode: outerNode)
        }
        var triangles: [Int] = []
        list.earcutLinked(outerNode, &triangles, pass: 0)
        return (points, triangles)
    }
}

/// 輪の点を双方向の循環リストとして持つ（配列と添字で表す）。
private final class EarcutList {
    let points: [SIMD2<Double>]
    var x: [Double] = []
    var y: [Double] = []
    /// 元の points の添字
    var source: [Int] = []
    var prev: [Int] = []
    var next: [Int] = []
    var steiner: [Bool] = []

    init(points: [SIMD2<Double>]) {
        self.points = points
    }

    // MARK: リストの操作

    func insert(_ i: Int, after last: Int?) -> Int {
        let p: Int = x.count
        x.append(points[i].x)
        y.append(points[i].y)
        source.append(i)
        steiner.append(false)
        if let l = last {
            next.append(next[l])
            prev.append(l)
            prev[next[l]] = p
            next[l] = p
        } else {
            prev.append(p)
            next.append(p)
        }
        return p
    }

    func copyNode(_ a: Int) -> Int {
        let p: Int = x.count
        x.append(x[a])
        y.append(y[a])
        source.append(source[a])
        steiner.append(steiner[a])
        prev.append(p)
        next.append(p)
        return p
    }

    func remove(_ p: Int) {
        next[prev[p]] = next[p]
        prev[next[p]] = prev[p]
    }

    func linkedList(start: Int, end: Int, clockwise: Bool) -> Int? {
        if end - start < 3 { return nil }
        var last: Int?
        if clockwise == (signedArea(start: start, end: end) > 0) {
            for i in start..<end {
                last = insert(i, after: last)
            }
        } else {
            for i in stride(from: end - 1, through: start, by: -1) {
                last = insert(i, after: last)
            }
        }
        if let l = last, equals(l, next[l]) {
            let n: Int = next[l]
            remove(l)
            last = n
        }
        return last
    }

    func signedArea(start: Int, end: Int) -> Double {
        var sum: Double = 0
        var j: Int = end - 1
        for i in start..<end {
            let dx: Double = points[j].x - points[i].x
            let sy: Double = points[i].y + points[j].y
            sum += dx * sy
            j = i
        }
        return sum
    }

    // MARK: 幾何の判定

    func area(_ p: Int, _ q: Int, _ r: Int) -> Double {
        let a: Double = (y[q] - y[p]) * (x[r] - x[q])
        let b: Double = (x[q] - x[p]) * (y[r] - y[q])
        return a - b
    }

    func equals(_ a: Int, _ b: Int) -> Bool {
        return x[a] == x[b] && y[a] == y[b]
    }

    static func pointInTriangle(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ cx: Double, _ cy: Double,
                                _ px: Double, _ py: Double) -> Bool {
        let s1: Bool = (cx - px) * (ay - py) >= (ax - px) * (cy - py)
        let s2: Bool = (ax - px) * (by - py) >= (bx - px) * (ay - py)
        let s3: Bool = (bx - px) * (cy - py) >= (cx - px) * (by - py)
        return s1 && s2 && s3
    }

    static func sign(_ v: Double) -> Int {
        if v > 0 { return 1 }
        if v < 0 { return -1 }
        return 0
    }

    func onSegment(_ p: Int, _ q: Int, _ r: Int) -> Bool {
        let inX: Bool = x[q] <= max(x[p], x[r]) && x[q] >= min(x[p], x[r])
        let inY: Bool = y[q] <= max(y[p], y[r]) && y[q] >= min(y[p], y[r])
        return inX && inY
    }

    func intersects(_ p1: Int, _ q1: Int, _ p2: Int, _ q2: Int) -> Bool {
        let o1: Int = EarcutList.sign(area(p1, q1, p2))
        let o2: Int = EarcutList.sign(area(p1, q1, q2))
        let o3: Int = EarcutList.sign(area(p2, q2, p1))
        let o4: Int = EarcutList.sign(area(p2, q2, q1))
        if o1 != o2 && o3 != o4 { return true }
        if o1 == 0 && onSegment(p1, p2, q1) { return true }
        if o2 == 0 && onSegment(p1, q2, q1) { return true }
        if o3 == 0 && onSegment(p2, p1, q2) { return true }
        if o4 == 0 && onSegment(p2, q1, q2) { return true }
        return false
    }

    func intersectsPolygon(_ a: Int, _ b: Int) -> Bool {
        var p: Int = a
        repeat {
            let n: Int = next[p]
            let touches: Bool = source[p] == source[a] || source[n] == source[a] || source[p] == source[b] || source[n] == source[b]
            if !touches && intersects(p, n, a, b) { return true }
            p = n
        } while p != a
        return false
    }

    func locallyInside(_ a: Int, _ b: Int) -> Bool {
        if area(prev[a], a, next[a]) < 0 {
            return area(a, b, next[a]) >= 0 && area(a, prev[a], b) >= 0
        }
        return area(a, b, prev[a]) < 0 || area(a, next[a], b) < 0
    }

    func middleInside(_ a: Int, _ b: Int) -> Bool {
        var p: Int = a
        var inside: Bool = false
        let px: Double = (x[a] + x[b]) / 2
        let py: Double = (y[a] + y[b]) / 2
        repeat {
            let n: Int = next[p]
            if (y[p] > py) != (y[n] > py) && y[n] != y[p] {
                let crossX: Double = (x[n] - x[p]) * (py - y[p]) / (y[n] - y[p]) + x[p]
                if px < crossX { inside = !inside }
            }
            p = n
        } while p != a
        return inside
    }

    func isValidDiagonal(_ a: Int, _ b: Int) -> Bool {
        if source[next[a]] == source[b] || source[prev[a]] == source[b] { return false }
        if intersectsPolygon(a, b) { return false }
        let visible: Bool = locallyInside(a, b) && locallyInside(b, a) && middleInside(a, b)
        if visible && (area(prev[a], a, prev[b]) != 0 || area(a, prev[b], b) != 0) { return true }
        return equals(a, b) && area(prev[a], a, next[a]) > 0 && area(prev[b], b, next[b]) > 0
    }

    // MARK: 耳の切り取り

    @discardableResult
    func filterPoints(_ start: Int, _ endNode: Int? = nil) -> Int {
        var end: Int = endNode ?? start
        var p: Int = start
        var again: Bool = false
        repeat {
            again = false
            if !steiner[p] && (equals(p, next[p]) || area(prev[p], p, next[p]) == 0) {
                remove(p)
                p = prev[p]
                end = p
                if p == next[p] { break }
                again = true
            } else {
                p = next[p]
            }
        } while again || p != end
        return end
    }

    func isEar(_ ear: Int) -> Bool {
        let a: Int = prev[ear]
        let b: Int = ear
        let c: Int = next[ear]
        if area(a, b, c) >= 0 { return false }
        let x0: Double = min(x[a], min(x[b], x[c]))
        let y0: Double = min(y[a], min(y[b], y[c]))
        let x1: Double = max(x[a], max(x[b], x[c]))
        let y1: Double = max(y[a], max(y[b], y[c]))
        var p: Int = next[c]
        while p != a {
            let inBox: Bool = x[p] >= x0 && x[p] <= x1 && y[p] >= y0 && y[p] <= y1
            if inBox && EarcutList.pointInTriangle(x[a], y[a], x[b], y[b], x[c], y[c], x[p], y[p])
                && area(prev[p], p, next[p]) >= 0 {
                return false
            }
            p = next[p]
        }
        return true
    }

    func earcutLinked(_ start: Int, _ triangles: inout [Int], pass: Int) {
        var ear: Int = start
        var stop: Int = ear
        while prev[ear] != next[ear] {
            let p: Int = prev[ear]
            let n: Int = next[ear]
            if isEar(ear) {
                triangles.append(source[p])
                triangles.append(source[ear])
                triangles.append(source[n])
                remove(ear)
                ear = next[n]
                stop = next[n]
                continue
            }
            ear = n
            if ear == stop {
                if pass == 0 {
                    earcutLinked(filterPoints(ear), &triangles, pass: 1)
                } else if pass == 1 {
                    let cured: Int = cureLocalIntersections(filterPoints(ear), &triangles)
                    earcutLinked(cured, &triangles, pass: 2)
                } else if pass == 2 {
                    splitEarcut(ear, &triangles)
                }
                break
            }
        }
    }

    func cureLocalIntersections(_ startNode: Int, _ triangles: inout [Int]) -> Int {
        var start: Int = startNode
        var p: Int = start
        repeat {
            let a: Int = prev[p]
            let b: Int = next[next[p]]
            if !equals(a, b) && intersects(a, p, next[p], b) && locallyInside(a, b) && locallyInside(b, a) {
                triangles.append(source[a])
                triangles.append(source[p])
                triangles.append(source[b])
                remove(next[p])
                remove(p)
                p = b
                start = b
            }
            p = next[p]
        } while p != start
        return filterPoints(p)
    }

    func splitEarcut(_ start: Int, _ triangles: inout [Int]) {
        var a: Int = start
        repeat {
            var b: Int = next[next[a]]
            while b != prev[a] {
                if source[a] != source[b] && isValidDiagonal(a, b) {
                    var c: Int = splitPolygon(a, b)
                    a = filterPoints(a, next[a])
                    c = filterPoints(c, next[c])
                    earcutLinked(a, &triangles, pass: 0)
                    earcutLinked(c, &triangles, pass: 0)
                    return
                }
                b = next[b]
            }
            a = next[a]
        } while a != start
    }

    /// a と b を橋でつなぐ。同じ輪なら 2 つに分かれ、外側と穴なら 1 つの輪になる。
    func splitPolygon(_ a: Int, _ b: Int) -> Int {
        let a2: Int = copyNode(a)
        let b2: Int = copyNode(b)
        let an: Int = next[a]
        let bp: Int = prev[b]
        next[a] = b
        prev[b] = a
        next[a2] = an
        prev[an] = a2
        next[b2] = a2
        prev[a2] = b2
        next[bp] = b2
        prev[b2] = bp
        return b2
    }

    // MARK: 穴

    func eliminateHoles(holeStarts: [Int], outerNode: Int) -> Int {
        var queue: [Int] = []
        for (k, start) in holeStarts.enumerated() {
            let end: Int = k + 1 < holeStarts.count ? holeStarts[k + 1] : points.count
            guard let list = linkedList(start: start, end: end, clockwise: false) else { continue }
            if list == next[list] { steiner[list] = true }
            queue.append(leftmost(list))
        }
        queue.sort { (a: Int, b: Int) -> Bool in x[a] < x[b] }
        var outer: Int = outerNode
        for hole in queue {
            outer = eliminateHole(hole, outer)
        }
        return outer
    }

    func eliminateHole(_ hole: Int, _ outerNode: Int) -> Int {
        guard let bridge = findHoleBridge(hole, outerNode) else { return outerNode }
        let bridgeReverse: Int = splitPolygon(bridge, hole)
        filterPoints(bridgeReverse, next[bridgeReverse])
        return filterPoints(bridge, next[bridge])
    }

    /// 穴のいちばん左の点から左へ光線を出し、外側の輪につなぐ点を探す（David Eberly の方法）。
    func findHoleBridge(_ hole: Int, _ outerNode: Int) -> Int? {
        var p: Int = outerNode
        let hx: Double = x[hole]
        let hy: Double = y[hole]
        var qx: Double = -Double.infinity
        var m: Int?
        repeat {
            let n: Int = next[p]
            if hy <= y[p] && hy >= y[n] && y[n] != y[p] {
                let cx: Double = x[p] + (hy - y[p]) * (x[n] - x[p]) / (y[n] - y[p])
                if cx <= hx && cx > qx {
                    qx = cx
                    m = x[p] < x[n] ? p : n
                    if cx == hx { return m }
                }
            }
            p = n
        } while p != outerNode
        guard let found = m else { return nil }
        var best: Int = found
        let stop: Int = found
        let mx: Double = x[found]
        let my: Double = y[found]
        var tanMin: Double = Double.infinity
        p = found
        repeat {
            let ax: Double = hy < my ? hx : qx
            let cx: Double = hy < my ? qx : hx
            if hx >= x[p] && x[p] >= mx && hx != x[p] && EarcutList.pointInTriangle(ax, hy, mx, my, cx, hy, x[p], y[p]) {
                let tan: Double = abs(hy - y[p]) / (hx - x[p])
                if locallyInside(p, hole) {
                    let better: Bool = tan < tanMin
                    let tie: Bool = tan == tanMin && (x[p] > x[best] || (x[p] == x[best] && sectorContainsSector(best, p)))
                    if better || tie {
                        best = p
                        tanMin = tan
                    }
                }
            }
            p = next[p]
        } while p != stop
        return best
    }

    func sectorContainsSector(_ m: Int, _ p: Int) -> Bool {
        return area(prev[m], m, prev[p]) < 0 && area(next[p], m, next[m]) < 0
    }

    func leftmost(_ start: Int) -> Int {
        var p: Int = start
        var result: Int = start
        repeat {
            if x[p] < x[result] || (x[p] == x[result] && y[p] < y[result]) { result = p }
            p = next[p]
        } while p != start
        return result
    }
}
