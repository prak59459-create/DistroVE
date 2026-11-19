import Foundation

/// プロジェクトのテンプレート（Q48: アプリが提供）。JSON で持つので GitHub から追加分を配れる（データのみ）。
struct TemplateDefinition: Identifiable, Codable, Sendable {
    struct TextItem: Codable, Sendable {
        var text: String
        var preset: String
        var start: Double
        var duration: Double
        var positionY: Double
    }

    var id: String
    var name: String
    var category: String
    var summary: String
    var aspect: AspectPreset
    var fps: Double
    /// 内蔵 BGM の ID
    var music: String?
    /// 何拍ごとに切り替えるか（BGM があるとき）
    var beatsPerCut: Int?
    /// BGM が無いときの 1 素材の長さ（秒）
    var slotSeconds: Double
    /// おすすめの素材数
    var slots: Int
    var transition: TransitionKind?
    var transitionSeconds: Double?
    var look: String?
    var effects: [EffectKind]
    var texts: [TextItem]
    var captions: Bool
}

enum TemplateLibrary {
    /// 内蔵テンプレート。型チェックを軽くするため、Swift のリテラルではなく JSON 文字列で持つ。
    static let builtinJSON: String = """
    [
      {"id":"phonk-edit","name":"phonk ビート編集","category":"音楽・MV","summary":"130BPM の phonk に合わせて 2 拍ごとに切り替え、シェイクとフラッシュを入れる縦型編集。",
       "aspect":"portrait9x16","fps":30,"music":"bgm.phonk","beatsPerCut":2,"slotSeconds":0.9,"slots":8,
       "transition":"flashWhite","transitionSeconds":0.15,"look":"phonkDark","effects":["shake","flash"],
       "texts":[{"text":"PHONK","preset":"phonk","start":0,"duration":2.5,"positionY":-0.3}],"captions":false},
      {"id":"tiktok-short","name":"縦型ショート","category":"ショート","summary":"9:16・テンポよく切り替え、大きめの字幕が入る SNS 向け。",
       "aspect":"portrait9x16","fps":30,"music":"bgm.upbeat","beatsPerCut":4,"slotSeconds":2,"slots":6,
       "transition":"zoomIn","transitionSeconds":0.3,"look":"vivid","effects":[],
       "texts":[{"text":"タイトルを入力","preset":"pop","start":0,"duration":2.5,"positionY":-0.32}],"captions":true},
      {"id":"vlog-opening","name":"Vlog オープニング","category":"Vlog","summary":"16:9。ゆったりした Lo-Fi とフィルム調の色、タイトルがふわっと出る。",
       "aspect":"landscape16x9","fps":30,"music":"bgm.lofi","beatsPerCut":8,"slotSeconds":4,"slots":5,
       "transition":"fade","transitionSeconds":0.6,"look":"film","effects":["grain"],
       "texts":[{"text":"MY VLOG","preset":"cinema","start":0.5,"duration":3.5,"positionY":0}],"captions":false},
      {"id":"music-video","name":"MV リリック","category":"音楽・MV","summary":"歌詞をタイプライターで表示。ビートに合わせてズームが脈打つ。",
       "aspect":"landscape16x9","fps":30,"music":"bgm.upbeat","beatsPerCut":4,"slotSeconds":2,"slots":8,
       "transition":"glitch","transitionSeconds":0.25,"look":"cyberpunk","effects":["zoomPulse"],
       "texts":[{"text":"歌詞をここに","preset":"caption","start":0,"duration":4,"positionY":0.3}],"captions":false},
      {"id":"education","name":"解説・授業","category":"仕事・教育","summary":"見出しの帯と字幕。落ち着いた色で、切り替えはクロスフェード。",
       "aspect":"landscape16x9","fps":30,"music":null,"beatsPerCut":null,"slotSeconds":6,"slots":4,
       "transition":"fade","transitionSeconds":0.4,"look":null,"effects":[],
       "texts":[{"text":"第 1 回　はじめに","preset":"band","start":0,"duration":4,"positionY":-0.36}],"captions":true},
      {"id":"reels-square","name":"正方形スライドショー","category":"SNS","summary":"1:1。写真を 2 秒ずつスライドでつなぐ。",
       "aspect":"square1x1","fps":30,"music":"bgm.lofi","beatsPerCut":4,"slotSeconds":2,"slots":10,
       "transition":"slideLeft","transitionSeconds":0.35,"look":"pastel","effects":[],
       "texts":[],"captions":false},
      {"id":"cinematic-trailer","name":"シネマティック予告","category":"Vlog","summary":"21:9 の黒帯風。ゆっくりした切り替えと大きなタイトル。",
       "aspect":"cinema21x9","fps":24,"music":"bgm.cinematic","beatsPerCut":4,"slotSeconds":3,"slots":6,
       "transition":"fadeBlack","transitionSeconds":0.8,"look":"tealOrange","effects":["vignette"],
       "texts":[{"text":"COMING SOON","preset":"cinema","start":1,"duration":3,"positionY":0}],"captions":false},
      {"id":"game-highlight","name":"ゲーム実況ハイライト","category":"ショート","summary":"RGB ずらしとグリッチで勢いを出す。3D キューブで場面転換。",
       "aspect":"landscape16x9","fps":60,"music":"bgm.drums","beatsPerCut":4,"slotSeconds":2,"slots":8,
       "transition":"cube3D","transitionSeconds":0.4,"look":"vivid","effects":["rgbSplit"],
       "texts":[{"text":"HIGHLIGHT","preset":"outline","start":0,"duration":2,"positionY":-0.3}],"captions":false}
    ]
    """

    static func builtin() -> [TemplateDefinition] {
        return decode(Data(builtinJSON.utf8))
    }

    static func decode(_ data: Data) -> [TemplateDefinition] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([TemplateDefinition].self, from: data) {
            return list
        }
        if let single = try? decoder.decode(TemplateDefinition.self, from: data) {
            return [single]
        }
        return []
    }

    /// テンプレートからプロジェクトを作る。media は選んだ素材、music は BGM 素材（内蔵 BGM を取り込んだもの）、beats は BGM のビート。
    static func makeProject(_ template: TemplateDefinition, media: [MediaAsset], music: MediaAsset?, beats: [Time]) -> Project {
        let canvas = CanvasSettings(aspect: template.aspect, shortSide: 1080, fps: template.fps)
        var project = Project(name: template.name, canvas: canvas)
        project.templateID = template.id
        project.media = media
        var sources: [AutoEdit.Source] = []
        for asset in media where asset.isVisual {
            var base: Clip = project.makeClip(for: asset)
            base.fitMode = template.aspect == .portrait9x16 ? .fill : .fit
            if let look = template.look {
                base.look = LookSettings(id: "builtin:" + look, intensity: 0.85)
            }
            let duration: Time = asset.hasFiniteDuration ? asset.duration : Time(seconds: 600)
            sources.append(AutoEdit.Source(mediaID: asset.id, name: asset.name, sourceStart: .zero, sourceDuration: duration,
                                           isStill: !asset.hasFiniteDuration, template: base))
        }
        var transition: ClipTransition?
        if let kind = template.transition {
            transition = ClipTransition(kind: kind, duration: Time(seconds: template.transitionSeconds ?? 0.4))
        }
        if let music = music {
            project.media.append(music)
            var bgm: Clip = project.makeClip(for: music)
            bgm.audio.fadeOut = Time(seconds: 1.5)
            project.placeAudio(bgm, at: .zero)
            project.setBeatMarkers(beats)
        }
        if !sources.isEmpty {
            var cutBeats: [Time] = beats
            if cutBeats.count < 2 || template.beatsPerCut == nil {
                cutBeats = []
                let count: Int = max(template.slots, sources.count)
                for i in 0...count {
                    cutBeats.append(Time(seconds: template.slotSeconds * Double(i)))
                }
            }
            let perCut: Int = (beats.count >= 2 ? template.beatsPerCut : nil) ?? 1
            let limit: Time? = music.map { $0.duration }
            _ = AutoEdit.beatSync(project: &project, sources: sources, beats: cutBeats, beatsPerCut: perCut,
                                  maxDuration: limit, transition: transition, effects: template.effects)
        }
        for item in template.texts {
            let preset: TextPresets.Preset = TextPresets.all.first { $0.id == item.preset } ?? TextPresets.simple()
            var content: TextContent = preset.content
            content.string = item.text
            var clip = Clip(kind: .text, name: item.text, start: Time(seconds: item.start), duration: Time(seconds: item.duration))
            clip.text = content
            clip.transform.positionY = Param(item.positionY)
            project.placeOverlay(clip, at: clip.start)
        }
        if template.captions {
            project.ensureSubtitleTrack()
        }
        return project
    }
}
