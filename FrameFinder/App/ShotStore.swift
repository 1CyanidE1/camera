import Combine
import Foundation
import ImageIO
import UIKit

struct ShotSource: Codable, Equatable {
    enum Kind: String, Codable {
        case heic, proRAW
    }

    var file: String
    var kind: Kind
}

struct ShotRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    var label: String
    var aesthetic: Double?
    var crop: CGRect?
    var reasons: [ShotReason]
    var rotation: PhotoRotation?
    var source: ShotSource?
    var previousCrop: CGRect?

    var imageFile: String { id.uuidString + ".heic" }
    var originalFile: String { id.uuidString + "-original.heic" }

    static func sourceFile(for id: UUID, kind: ShotSource.Kind) -> String {
        id.uuidString + (kind == .proRAW ? "-source.dng" : "-source.heic")
    }
}

final class ShotStore: ObservableObject {
    @Published private(set) var shots: [ShotRecord] = []
    @Published private(set) var usedBytes: Int64 = 0

    private let directory: URL
    private let queue = DispatchQueue(label: "shots.io", qos: .utility)

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
        measure()
    }

    func url(for file: String) -> URL {
        directory.appendingPathComponent(file)
    }

    func add(_ record: ShotRecord, viewer: Data, original: Data, source: Data?) {
        let imageURL = url(for: record.imageFile)
        let originalURL = url(for: record.originalFile)
        let sourceURL = record.source.map { url(for: $0.file) }
        queue.async {
            do {
                try viewer.write(to: imageURL, options: .atomic)
                try original.write(to: originalURL, options: .atomic)
                if let source, let sourceURL { try source.write(to: sourceURL, options: .atomic) }
            } catch {
                return
            }
            DispatchQueue.main.async {
                self.shots.insert(record, at: 0)
                self.save()
                self.measure()
            }
        }
    }

    func update(_ record: ShotRecord, viewer: Data?, original: Data?, completion: (() -> Void)? = nil) {
        let imageURL = url(for: record.imageFile)
        let originalURL = url(for: record.originalFile)
        queue.async {
            if let viewer { try? viewer.write(to: imageURL, options: .atomic) }
            if let original { try? original.write(to: originalURL, options: .atomic) }
            DispatchQueue.main.async {
                if let i = self.shots.firstIndex(where: { $0.id == record.id }) {
                    self.shots[i] = record
                }
                self.save()
                self.measure()
                completion?()
            }
        }
    }

    func delete(_ record: ShotRecord) {
        shots.removeAll { $0.id == record.id }
        save()
        var files = [url(for: record.imageFile), url(for: record.originalFile)]
        if let source = record.source { files.append(url(for: source.file)) }
        queue.async {
            for file in files { try? FileManager.default.removeItem(at: file) }
            DispatchQueue.main.async { self.measure() }
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

    private func measure() {
        let dir = directory
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let total = files.reduce(Int64(0)) { sum, file in
                sum + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            DispatchQueue.main.async { self.usedBytes = total }
        }
    }
}
