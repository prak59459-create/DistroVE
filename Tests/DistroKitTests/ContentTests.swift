import XCTest
@testable import DistroKit

/// GitHub から配る content/ のデータが、アプリで読めることを確かめる。
final class ContentTests: XCTestCase {
    func testPublishedContentIsReadable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("content")
        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(ContentManifest.self, from: manifestData)
        XCTAssertFalse(manifest.files.isEmpty)
        XCTAssertTrue(ContentManifest.isCompatible(appVersion: "0.1.0", minimum: manifest.minimumAppVersion))
        for file in manifest.files {
            XCTAssertTrue(ContentManifest.isSafePath(file.path), file.path)
            let data = try Data(contentsOf: root.appendingPathComponent(file.path))
            XCTAssertEqual(data.count, file.size, file.path)
            switch file.kind {
            case "template":
                let templates = TemplateLibrary.decode(data)
                XCTAssertFalse(templates.isEmpty, file.path)
                for template in templates {
                    let project = TemplateLibrary.makeProject(template, media: [], music: nil, beats: [])
                    XCTAssertEqual(project.canvas.aspect, template.aspect)
                }
            case "lut":
                let lut = try CubeLUT.parse(String(decoding: data, as: UTF8.self))
                XCTAssertGreaterThanOrEqual(lut.size, 2)
            default:
                XCTFail("unknown kind \(file.kind)")
            }
        }
    }
}
