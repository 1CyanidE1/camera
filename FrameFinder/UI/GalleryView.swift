import SwiftUI
import UIKit

struct GalleryView: View {
    @ObservedObject var store: ShotStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var showOriginal = false
    @State private var showReasons = true
    @State private var confirmDelete = false

    private var current: ShotRecord? {
        store.shots.first { $0.id == selection } ?? store.shots.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let shot = current {
                VStack(spacing: 0) {
                    header(shot)
                    if shot.crop != nil {
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
                            ShotPage(shot: item, store: store, showOriginal: showOriginal)
                                .tag(Optional(item.id))
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    ReasonsCard(shot: shot, expanded: $showReasons)
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
        .onAppear {
            if selection == nil { selection = store.shots.first?.id }
        }
        .onChange(of: store.shots.map(\.id)) { _, ids in
            if let id = selection, !ids.contains(id) { selection = ids.first }
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
                Text(shot.label)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
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

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(store.shots) { item in
                        ShotThumb(url: store.url(for: item.imageFile))
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
    @State private var image: UIImage?
    @State private var original: UIImage?

    var body: some View {
        Group {
            if showOriginal, let crop = shot.crop {
                if let original {
                    OriginalWithFrame(image: original, crop: crop)
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
        .task(id: showOriginal) {
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

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { geo in
                    let r = CGRect(x: crop.minX * geo.size.width, y: crop.minY * geo.size.height,
                                   width: crop.width * geo.size.width, height: crop.height * geo.size.height)
                    Canvas { ctx, size in
                        var dim = Path(CGRect(origin: .zero, size: size))
                        dim.addRect(r)
                        ctx.fill(dim, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                        ctx.stroke(Path(r), with: .color(.yellow), lineWidth: 2)
                    }
                }
            }
            .padding(.horizontal, 8)
    }
}

private struct ShotThumb: View {
    let url: URL
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
        .task(id: url) {
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
