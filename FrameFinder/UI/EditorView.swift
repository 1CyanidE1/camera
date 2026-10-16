import Combine
import SwiftUI
import UIKit

final class EditSession: ObservableObject {
    @Published var develop: DevelopParams { didSet { requestPreview() } }
    @Published var color: ColorParams { didSet { requestPreview() } }
    @Published var preview: UIImage?
    @Published var working = false
    @Published var message: String?

    let record: ShotRecord
    let source: RenderSource?
    let neuralAvailable: Bool
    private let store: ShotStore
    private let queue = DispatchQueue(label: "edit.render", qos: .userInitiated)
    private var pending = false
    private var busy = false

    init(record: ShotRecord, store: ShotStore) {
        let prepared = Self.withLegacySource(record, store: store)
        self.record = prepared
        self.store = store
        source = RenderSource(record: prepared, store: store)
        develop = prepared.develop ?? DevelopParams()
        color = prepared.color ?? ColorParams()
        neuralAvailable = NeuralColor.shared.isAvailable
        requestPreview()
    }

    var isRAW: Bool { record.source?.kind == .proRAW }

    func requestPreview() {
        pending = true
        pump()
    }

    private func pump() {
        guard pending, !busy, let source else { return }
        pending = false
        busy = true
        let develop = self.develop, color = self.color
        queue.async {
            let image = RenderPipeline.render(source, develop: develop, color: color, maxSide: 1600, draft: true)
                .flatMap(RenderPipeline.uiImage)
            DispatchQueue.main.async {
                if let image { self.preview = image }
                self.busy = false
                self.pump()
            }
        }
    }

    func apply(completion: @escaping () -> Void) {
        guard let source else {
            completion()
            return
        }
        working = true
        let develop = self.develop, color = self.color
        var updated = record
        updated.develop = develop
        updated.color = color
        updated.revision = (record.revision ?? 0) + 1
        queue.async {
            let viewer = RenderPipeline.render(source, develop: develop, color: color, maxSide: 3072, draft: false)
                .flatMap { RenderPipeline.encode($0, source: nil, quality: 0.85) }
            let original = RenderPipeline.render(source, develop: develop, color: color, crop: false, maxSide: 1280, draft: false)
                .flatMap { RenderPipeline.encode($0, source: nil, quality: 0.8) }
            DispatchQueue.main.async {
                self.store.update(updated, viewer: viewer, original: original) {
                    self.working = false
                    completion()
                }
            }
        }
    }

    func exportToPhotos() {
        guard let source else { return }
        working = true
        let develop = self.develop, color = self.color
        queue.async {
            let data = RenderPipeline.render(source, develop: develop, color: color, maxSide: nil, draft: false)
                .flatMap { RenderPipeline.encode($0, source: source, quality: 0.92) }
            guard let data else {
                DispatchQueue.main.async {
                    self.working = false
                    self.message = "Не удалось отрендерить снимок"
                }
                return
            }
            PhotoLibrary.save([data]) { ok in
                DispatchQueue.main.async {
                    self.working = false
                    self.message = ok ? "Сохранено в «Фото»" : "Нет доступа к «Фото»"
                }
            }
        }
    }

    private static func withLegacySource(_ record: ShotRecord, store: ShotStore) -> ShotRecord {
        guard record.source == nil else { return record }
        let file = record.id.uuidString + "-legacy.heic"
        let target = store.url(for: file)
        if !FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.copyItem(at: store.url(for: record.imageFile), to: target)
        }
        var updated = record
        updated.source = ShotSource(file: file, kind: .heic, precropped: true)
        return updated
    }
}

struct EditorView: View {
    @StateObject private var session: EditSession
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    init(record: ShotRecord, store: ShotStore) {
        _session = StateObject(wrappedValue: EditSession(record: record, store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if let image = session.preview {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
                if session.working {
                    Color.black.opacity(0.4)
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)

            Picker("Раздел", selection: $tab) {
                Text("Проявка").tag(0)
                Text("Цвет").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                if tab == 0 { developControls } else { colorControls }
            }
            .frame(height: 250)

            Button {
                session.exportToPhotos()
            } label: {
                Label("Сохранить в Фото", systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(session.working)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let message = session.message {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 60)
                    .onTapGesture { session.message = nil }
                    .task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        session.message = nil
                    }
            }
        }
    }

    private var header: some View {
        HStack {
            Button("Отмена") { dismiss() }
            Spacer()
            Text(session.isRAW ? "Проявка RAW" : "Правка")
                .font(.headline)
            Spacer()
            Button("Готово") {
                session.apply { dismiss() }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.yellow)
            .disabled(session.working)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var developControls: some View {
        VStack(spacing: 12) {
            AdjustRow(title: "Экспозиция", value: $session.develop.exposure, range: -2...2, format: "%+.1f EV")
            AdjustRow(title: "Температура", value: $session.develop.temperature, range: -1...1, format: "%+.0f", scale: 100)
            AdjustRow(title: "Оттенок", value: $session.develop.tint, range: -1...1, format: "%+.0f", scale: 100)
            AdjustRow(title: "Света", value: $session.develop.highlights, range: -1...1, format: "%+.0f", scale: 100)
            AdjustRow(title: "Тени", value: $session.develop.shadows, range: -1...1, format: "%+.0f", scale: 100)
            AdjustRow(title: "Контраст", value: $session.develop.contrast, range: -1...1, format: "%+.0f", scale: 100)
            AdjustRow(title: "Насыщенность", value: $session.develop.saturation, range: -1...1, format: "%+.0f", scale: 100)
            Toggle("Плоский профиль (лог)", isOn: $session.develop.flat)
                .tint(.yellow)
                .font(.subheadline)
            Button("Сбросить проявку") { session.develop = DevelopParams() }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 16)
    }

    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LookLibrary.all) { look in
                        let enabled = look.kind != .cloud && (look.kind != .neural || session.neuralAvailable)
                        Button {
                            session.color.look = look.id
                        } label: {
                            VStack(spacing: 2) {
                                Text(look.title)
                                    .font(.footnote.weight(.semibold))
                                if look.kind == .cloud {
                                    Text("скоро").font(.caption2)
                                } else if look.kind == .neural && !session.neuralAvailable {
                                    Text("нет модели").font(.caption2)
                                }
                            }
                            .foregroundStyle(session.color.look == look.id ? Color.black : Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(session.color.look == look.id ? Color.yellow : Color.white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .opacity(enabled ? 1 : 0.4)
                        }
                        .disabled(!enabled)
                    }
                }
                .padding(.horizontal, 16)
            }
            if session.color.look != "none" {
                AdjustRow(title: "Сила", value: $session.color.intensity, range: 0...1, format: "%.0f%%", scale: 100)
                    .padding(.horizontal, 16)
            }
            Text(colorHint)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 16)
        }
    }

    private var colorHint: String {
        switch session.color.look {
        case "auto": return "Алгоритм Apple: баланс белого, тени, света и насыщенность под этот снимок."
        case "neural": return "Нейросеть подбирает цвет под снимок по примерам ретушёров."
        case "none": return "Выбери образ или авто-коррекцию."
        default: return "Образ задан формулами и накладывается как 3D-LUT."
        }
    }
}

private struct AdjustRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale = 1.0

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: format, value * scale))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .onTapGesture(count: 2) { value = range.contains(0) ? 0 : range.upperBound }
            }
            Slider(value: $value, in: range)
                .tint(.yellow)
        }
    }
}
