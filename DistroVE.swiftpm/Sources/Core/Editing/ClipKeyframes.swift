import Foundation

extension Clip {
    /// すべてのキーフレームを delta だけずらす（先頭トリム後に動きの位置を保つ）。
    mutating func shiftKeyframes(by delta: Time) {
        if delta.ticks == 0 { return }
        transform = transform.shifted(by: delta)
        color = color.shifted(by: delta)
        for i in effects.indices {
            effects[i].params = effects[i].params.shifted(by: delta)
        }
        if var m = mask {
            m.centerX = m.centerX.shifted(by: delta)
            m.centerY = m.centerY.shifted(by: delta)
            m.width = m.width.shifted(by: delta)
            m.height = m.height.shifted(by: delta)
            m.rotation = m.rotation.shifted(by: delta)
            m.feather = m.feather.shifted(by: delta)
            mask = m
        }
        audio.volume = audio.volume.shifted(by: delta)
        if var content = object3D {
            content.positionZ = content.positionZ.shifted(by: delta)
            object3D = content
        }
    }

    /// クリップ内の時刻 t で分けたときの、前半・後半のキーフレームを作る。
    func splitKeyframes(at t: Time) -> (Clip, Clip) {
        var left: Clip = self
        var right: Clip = self
        let tr: (Transform, Transform) = transform.split(at: t)
        left.transform = tr.0
        right.transform = tr.1
        let co: (ParamSet, ParamSet) = color.split(at: t)
        left.color = co.0
        right.color = co.1
        for i in effects.indices {
            let parts: (ParamSet, ParamSet) = effects[i].params.split(at: t)
            left.effects[i].params = parts.0
            right.effects[i].params = parts.1
            right.effects[i].id = UUID()
        }
        if let m = mask {
            var lm: MaskSettings = m
            var rm: MaskSettings = m
            let cx: (Param, Param) = m.centerX.split(at: t)
            let cy: (Param, Param) = m.centerY.split(at: t)
            let w: (Param, Param) = m.width.split(at: t)
            let h: (Param, Param) = m.height.split(at: t)
            let r: (Param, Param) = m.rotation.split(at: t)
            let f: (Param, Param) = m.feather.split(at: t)
            lm.centerX = cx.0
            rm.centerX = cx.1
            lm.centerY = cy.0
            rm.centerY = cy.1
            lm.width = w.0
            rm.width = w.1
            lm.height = h.0
            rm.height = h.1
            lm.rotation = r.0
            rm.rotation = r.1
            lm.feather = f.0
            rm.feather = f.1
            left.mask = lm
            right.mask = rm
        }
        let vol: (Param, Param) = audio.volume.split(at: t)
        left.audio.volume = vol.0
        right.audio.volume = vol.1
        if let content = object3D {
            let z: (Param, Param) = content.positionZ.split(at: t)
            left.object3D?.positionZ = z.0
            right.object3D?.positionZ = z.1
        }
        return (left, right)
    }

    /// 長さを変えたときに、範囲外になったキーフレームを片付ける（最後のキーは残す）。
    mutating func clampKeyframes() {
        let limit: Time = duration
        transform.positionX = Clip.clampParam(transform.positionX, limit)
        transform.positionY = Clip.clampParam(transform.positionY, limit)
        transform.scale = Clip.clampParam(transform.scale, limit)
        transform.rotation = Clip.clampParam(transform.rotation, limit)
        transform.opacity = Clip.clampParam(transform.opacity, limit)
        transform.rotationX = Clip.clampParam(transform.rotationX, limit)
        transform.rotationY = Clip.clampParam(transform.rotationY, limit)
        audio.volume = Clip.clampParam(audio.volume, limit)
        if let content = object3D {
            object3D?.positionZ = Clip.clampParam(content.positionZ, limit)
        }
    }

    static func clampParam(_ param: Param, _ limit: Time) -> Param {
        if param.keys.isEmpty { return param }
        var kept: [ParamKey] = param.keys.filter { $0.time >= .zero && $0.time <= limit }
        if kept.isEmpty, let last = param.keys.last {
            kept = [ParamKey(time: limit, value: last.value, easing: last.easing)]
        }
        return Param(value: param.value, keys: kept)
    }
}
