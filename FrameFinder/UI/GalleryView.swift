import SwiftUI
import UIKit

struct GalleryView: View {
    @ObservedObject var store: ShotStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var showOriginal = false
    @State private var showReasons = true
    @State private var confirmDelete = false
    @State private var editing: ShotRecord?
    @State private var recheckRunning: UUID?
    @State private var proposal: (id: UUID, result: RecheckResult)?
    @State private var exportOffer: UUID?
    @State private var toast: String?
    @State private var exporting = false

    private var current: ShotRecord? {
        store.shots.first { $0.id == selection } ?? store.shots.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let shot = current {
                VStack(spacing: 0) {
                    header(shot)
                    if shot.crop != nil || proposalRect(for: shot) != nil {
                        Picker("Вид", selection: $showOriginal) {
                            Text("Кадр").tag(false)
                            Text("Исходник с рамкой").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }
                    TabView(selection: $selection) {
                        ForEach(store.shots) { item in
                            ShotPage(shot: item, store: store, showOriginal: showOriginal,
                                     proposal: proposalRect(for: item))
                                .tag(Optional(item.id))
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    if let found = proposal, found.id == shot.id {
                        ProposalCard(result: found.result,
                                     onUse: { use(found.result, for: shot) },
                                     onDismiss: { withAnimation { proposal = nil } })
                    } else {
                        ReasonsCard(shot: shot, expanded: $showReasons)
                        recheckButton(shot)
                    }
                    strip
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 44))
                    Text("Пока нет снимков")
                    Button("Закрыть") { dismiss() }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.white)
            }
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let toast {
                    Text(toast)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                if let id = exportOffer, let shot = store.shots.first(where: { $0.id == id }) {
                    Button {
                        export(shot)
                    } label: {
                        Label(exporting ? "Сохраняю…" : "Сохранить новый кадр в Фото", systemImage: "square.and.arrow.down")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.yellow, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .disabled(exporting)
                }
            }
            .padding(.bottom, 90)
        }
        .onAppear {
            if selection == nil { selection = store.shots.first?.id }
        }
        .onChange(of: store.shots.map(\.id)) { _, ids in
            if let id = selection, !ids.contains(id) { selection = ids.first }
        }
        .fullScreenCover(item: $editing) { record in
            EditorView(record: record, store: store)
        }
        .confirmationDialog("Удалить снимок из приложения?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let shot = current { store.delete(shot) }
            }
        } message: {
            Text("В «Фото» он останется.")
        }
    }

    private func header(_ shot: ShotRecord) -> some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text(shot.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote.weight(.semibold))
                Text(subtitle(shot))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button { editing = shot } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
            ShareLink(item: store.url(for: shot.imageFile)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
            Button { confirmDelete = true } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func proposalRect(for shot: ShotRecord) -> CGRect? {
        guard let found = proposal, found.id == shot.id else { return nil }
        return found.result.crop
    }

    private func recheckButton(_ shot: ShotRecord) -> some View {
        let available = shot.source != nil && shot.source?.precropped != true
        return Button {
            recheck(shot)
        } label: {
            HStack(spacing: 8) {
                if recheckRunning == shot.id {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "sparkle.magnifyingglass")
                }
                Text(available ? "Перепроверить кадр" : "Перепроверка недоступна для старых снимков")
                    .font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .foregroundStyle(.white)
        .disabled(!available || recheckRunning != nil)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func recheck(_ shot: ShotRecord) {
        recheckRunning = shot.id
        let store = store
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await Recheck.run(record: shot, store: store)
            }.value
            recheckRunning = nil
            if let result {
                withAnimation {
                    proposal = (shot.id, result)
                    showOriginal = true
                }
            } else {
                show("Твой кадр уже лучший из найденных")
            }
        }
    }

    private func use(_ result: RecheckResult, for shot: ShotRecord) {
        var updated = shot
        updated.previousCrop = shot.crop
        updated.crop = result.crop
        updated.label = result.label
        updated.reasons = result.reasons
        updated.aesthetic = result.aesthetic
        updated.revision = (shot.revision ?? 0) + 1
        let store = store
        DispatchQueue.global(qos: .userInitiated).async {
            let viewer = RenderPipeline.viewerData(for: updated, store: store)
            DispatchQueue.main.async {
                store.update(updated, viewer: viewer, original: nil) {
                    withAnimation {
                        proposal = nil
                        showOriginal = false
                        exportOffer = updated.id
                    }
                    show("Кадр обновлён")
                }
            }
        }
    }

    private func export(_ shot: ShotRecord) {
        exporting = true
        let store = store
        DispatchQueue.global(qos: .userInitiated).async {
            let data = RenderPipeline.fullData(for: shot, store: store)
            let finish: (Bool) -> Void = { ok in
                DispatchQueue.main.async {
                    exporting = false
                    exportOffer = nil
                    show(ok ? "Сохранено в «Фото»" : "Не удалось сохранить")
                }
            }
            guard let data else {
                finish(false)
                return
            }
            PhotoLibrary.save([data], completion: finish)
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toast == text { withAnimation { toast = nil } }
        }
    }

    private func subtitle(_ shot: ShotRecord) -> String {
        var parts = [shot.label]
        if shot.source?.kind == .proRAW { parts.append("RAW") }
        parts.append(ByteCountFormatter.string(fromByteCount: store.usedBytes, countStyle: .file) + " в приложении")
        return parts.joined(separator: " · ")
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(store.shots) { item in
                        ShotThumb(url: store.url(for: item.imageFile), revision: item.revision ?? 0)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white, lineWidth: item.id == current?.id ? 2 : 0)
                            )
                            .id(item.id)
                            .onTapGesture { selection = item.id }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 60)
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ShotPage: View {
    let shot: ShotRecord
    let store: ShotStore
    let showOriginal: Bool
    let proposal: CGRect?
    @State private var image: UIImage?
    @State private var original: UIImage?
    @State private var loadedRevision = 0

    var body: some View {
        Group {
            if showOriginal, shot.crop != nil || proposal != nil {
                if let original {
                    OriginalWithFrame(image: original, crop: shot.crop ?? .unit, proposal: proposal)
                } else {
                    ProgressView().tint(.white)
                }
            } else if let image {
                ZoomableImage(image: image)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(showOriginal)-\(shot.revision ?? 0)") {
            if loadedRevision != (shot.revision ?? 0) {
                loadedRevision = shot.revision ?? 0
                image = nil
                original = nil
            }
            if showOriginal {
                if original == nil { original = await ShotStore.loadImage(store.url(for: shot.originalFile)) }
            } else if image == nil {
                image = await ShotStore.loadImage(store.url(for: shot.imageFile))
            }
        }
    }
}

private struct OriginalWithFrame: View {
    let image: UIImage
    let crop: CGRect
    let proposal: CGRect?

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { geo in
                    let r = CGRect(x: crop.minX * geo.size.width, y: crop.minY * geo.size.height,
                                   width: crop.width * geo.size.width, height: crop.height * geo.size.height)
                    let p = proposal.map {
                        CGRect(x: $0.minX * geo.size.width, y: $0.minY * geo.size.height,
                               width: $0.width * geo.size.width, height: $0.height * geo.size.height)
                    }
                    Canvas { ctx, size in
                        var dim = Path(CGRect(origin: .zero, size: size))
                        dim.addRect(p ?? r)
                        ctx.fill(dim, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                        ctx.stroke(Path(r), with: .color(.yellow), lineWidth: 2)
                        if let p {
                            ctx.stroke(Path(p), with: .color(.green), style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
    }
}

private struct ShotThumb: View {
    let url: URL
    let revision: Int
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: "\(url.lastPathComponent)-\(revision)") {
            image = await ShotStore.loadThumbnail(url)
        }
    }
}

private struct ReasonsCard: View {
    let shot: ShotRecord
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Почему этот кадр")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let a = shot.aesthetic {
                        Text("★ " + String(format: "%.1f", a * 10))
                            .font(.footnote.weight(.semibold))
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.footnote.weight(.semibold))
                }
            }
            if expanded {
                if shot.reasons.isEmpty {
                    Text("Снято целиком, без обрезки по рамке.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    ReasonList(reasons: shot.reasons)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomScrollView {
        ZoomScrollView()
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.setImage(image)
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        zoomScale = 1
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 {
            imageView.frame = bounds
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let p = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

private struct ProposalCard: View {
    let result: RecheckResult
    let onUse: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.green)
                Text("Нашёл кадр лучше на \(Int(((result.gain - 1) * 100).rounded()))% · \(result.label)")
                    .font(.subheadline.weight(.semibold))
            }
            ReasonList(reasons: Array(result.reasons.prefix(5)))
            HStack(spacing: 10) {
                Button(action: onDismiss) {
                    Text("Оставить мой")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                Button(action: onUse) {
                    Text("Использовать")
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.green, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
