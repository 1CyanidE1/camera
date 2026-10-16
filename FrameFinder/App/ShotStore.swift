import Combine
import Foundation
import ImageIO
import UIKit

struct ShotRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let label: String
    let aesthetic: Double?
    let crop: CGRect?
    let reasons: [ShotReason]

    var imageFile: String { id.uuidString + ".heic" }
    var originalFile: String { id.uuidString + "-original.heic" }
}

final class ShotStore: ObservableObject {
    @Published private(set) var shots: [ShotRecord] = []

    private let directory: URL
    private let queue = DispatchQueue(label: "shots.io", qos: .utility)

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func url(for file: String) -> URL {
        directory.appendingPathComponent(file)
    }

    func add(_ record: ShotRecord, viewer: Data, original: Data) {
        let imageURL = url(for: record.imageFile)
        let originalURL = url(for: record.originalFile)
        queue.async {
            do {
                try viewer.write(to: imageURL, options: .atomic)
                try original.write(to: originalURL, options: .atomic)
            } catch {
                return
            }
            DispatchQueue.main.async {
                self.shots.insert(record, at: 0)
                self.save()
            }
        }
    }

    func delete(_ record: ShotRecord) {
        shots.removeAll { $0.id == record.id }
        save()
        let files = [url(for: record.imageFile), url(for: record.originalFile)]
        queue.async {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    func latestThumbnail() -> UIImage? {
        guard let shot = shots.first,
              let source = CGImageSourceCreateWithURL(url(for: shot.imageFile) as CFURL, nil) else { return nil }
        return PhotoProcessor.thumbnail(from: source, maxSide: 240)
    }

    static func loadImage(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            UIImage(contentsOfFile: url.path)?.preparingForDisplay()
        }.value
    }

    static func loadThumbnail(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return PhotoProcessor.thumbnail(from: source, maxSide: 180)
        }.value
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([ShotRecord].self, from: data) else { return }
        shots = list.filter { FileManager.default.fileExists(atPath: url(for: $0.imageFile).path) }
    }

    private func save() {
        let snapshot = shots
        let target = indexURL
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }
}
