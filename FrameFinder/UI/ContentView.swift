import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = CameraModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .denied:
                MessageView(icon: "camera.fill",
                            text: "Нужен доступ к камере, чтобы искать кадр.",
                            button: "Открыть настройки") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            case .failed:
                MessageView(icon: "exclamationmark.triangle", text: "Не удалось запустить камеру.", button: nil, action: {})
            case .starting, .running:
                camera
            }
        }
        .onAppear { model.start() }
        .fullScreenCover(isPresented: $model.showGallery, onDismiss: model.refreshThumbnail) {
            GalleryView(store: model.shots)
        }
    }

    private var camera: some View {
        VStack(spacing: 14) {
            TopBar(model: model, live: model.live)
            viewfinder
            ProBar(model: model, live: model.live)
            Spacer(minLength: 0)
            ZoomBar(model: model, live: model.live)
            BottomBar(model: model, live: model.live)
        }
        .padding(.bottom, 10)
    }

    private var viewfinder: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreview(session: model.pipeline.session, ready: model.info != nil)
                FrameOverlay(live: model.live, explain: model.explain)
                if model.explain {
                    ExplainPanel(live: model.live)
                        .transition(.opacity)
                }
                ViewfinderGestures(
                    onTap: { model.tap(at: $0) },
                    onLongPress: { model.longPress(at: $0) },
                    canPan: { model.canAdjustBias },
                    onPan: { model.biasDrag($0, ended: $1) },
                    onPinch: { scale, ended in
                        if ended { model.pinchEnded() } else { model.pinchChanged(scale) }
                    }
                )
                if let marker = model.focusMarker {
                    FocusMarkerView(marker: marker, bias: model.exposureBias,
                                    adjusting: model.adjustingBias, size: geo.size)
                        .transition(.opacity)
                }
                if model.focusMarker?.locked == true {
                    VStack {
                        Text("AE/AF ЗАФИКСИРОВАНО")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.yellow, in: RoundedRectangle(cornerRadius: 4))
                            .padding(.top, 10)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
                if model.flash {
                    Color.black.opacity(0.85).allowsHitTesting(false)
                }
                if let toast = model.toast {
                    VStack {
                        Text(toast)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 12)
                        Spacer()
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(model.info?.imageAspect ?? 0.75, contentMode: .fit)
        .clipped()
    }
}

private struct ProBar: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var live: LiveState

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(FocusMode.allCases.filter { $0 != .manual }) { mode in
                    Button {
                        model.focusMode = mode
                    } label: {
                        Text(mode.title)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(model.focusMode == mode ? Color.black : Color.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(model.focusMode == mode ? Color.yellow : Color.clear, in: Capsule())
                    }
                }
            }
            .padding(2)
            .background(.white.opacity(0.1), in: Capsule())
            Spacer(minLength: 0)
            Text(readout)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
    }

    private var readout: String {
        let r = live.overlay.readout
        guard r.iso > 0 else { return "" }
        return "ISO \(Int(r.iso.rounded()))  \(Self.shutter(r.duration))  EV \(String(format: "%+.1f", r.bias))"
    }

    static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        if seconds >= 0.95 { return String(format: "%.1f\"", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }
}

private struct TopBar: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var live: LiveState

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Формат кадра", selection: $model.aspect) {
                    ForEach(AspectMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } label: {
                Label(model.aspect.title, systemImage: "aspectratio")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
            }

            Spacer(minLength: 0)
            Text(status)
                .font(.footnote.weight(.medium))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { model.explain.toggle() }
            } label: {
                Image(systemName: model.explain ? "questionmark.circle.fill" : "questionmark.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(model.explain ? Color.yellow : Color.white)
                    .frame(width: 34, height: 30)
                    .background(.white.opacity(0.12), in: Capsule())
            }

            Menu {
                Toggle("Сохранять и оригинал", isOn: $model.saveOriginal)
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 30)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var status: String {
        guard let frame = live.overlay.frame else { return "Ищу удачный кадр…" }
        if frame.aligned { return "Идеально — снимай!" }
        if frame.visible < 0.5 { return "Кадр ушёл — вернись по стрелке" }
        if frame.locked { return "Рамка закреплена" }
        return "Жми спуск — кадр обрежется сам"
    }

    private var statusColor: Color {
        guard let frame = live.overlay.frame else { return .white.opacity(0.7) }
        if frame.aligned { return .green }
        return frame.locked ? .yellow : .white
    }
}

private struct ZoomBar: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var live: LiveState

    var body: some View {
        HStack(spacing: 8) {
            if let info = model.info {
                ForEach(info.presets, id: \.self) { factor in
                    let value = factor / info.baseZoom
                    let active = abs(live.overlay.zoom - value) / value < 0.05
                    Button {
                        model.selectZoom(factor)
                    } label: {
                        Text(active ? Self.format(live.overlay.zoom) + "×" : Self.format(value))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(active ? Color.yellow : Color.white)
                            .frame(minWidth: 38, minHeight: 38)
                            .background(.white.opacity(active ? 0.2 : 0.1), in: Circle())
                    }
                }
                if !info.presets.contains(where: { abs(live.overlay.zoom - $0 / info.baseZoom) / ($0 / info.baseZoom) < 0.05 }) {
                    Text(Self.format(live.overlay.zoom) + "×")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 6)
                }
            }
            if let k = model.fitMultiplier, live.overlay.frame?.visible ?? 0 > 0.6 {
                Button {
                    model.fitToFrame()
                } label: {
                    Label("Приблизить ×" + Self.format(k), systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 34)
                        .background(.white.opacity(0.12), in: Capsule())
                }
            }
        }
        .frame(height: 40)
        .animation(.easeInOut(duration: 0.2), value: model.fitMultiplier == nil)
    }

    static func format(_ v: CGFloat) -> String {
        if v < 1 { return String(format: "%.1f", v).replacingOccurrences(of: "0.", with: ".") }
        if abs(v - v.rounded()) < 0.05 { return String(Int(v.rounded())) }
        return String(format: "%.1f", v)
    }
}

private struct BottomBar: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var live: LiveState

    var body: some View {
        HStack {
            Button {
                model.showGallery = true
            } label: {
                Group {
                    if let image = model.thumbnail {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Spacer()

            Button(action: model.shoot) {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                    Circle()
                        .fill(live.overlay.frame?.aligned == true ? Color.green : Color.white)
                        .frame(width: 64, height: 64)
                        .scaleEffect(model.busy ? 0.88 : 1)
                }
            }
            .disabled(model.busy)
            .animation(.easeOut(duration: 0.15), value: model.busy)

            Spacer()

            Button(action: model.toggleLock) {
                let locked = live.overlay.frame?.locked ?? false
                Image(systemName: locked ? "lock.fill" : "lock.open")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(locked ? Color.yellow : Color.white)
                    .frame(width: 54, height: 54)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .disabled(live.overlay.frame == nil)
            .opacity(live.overlay.frame == nil ? 0.4 : 1)
        }
        .padding(.horizontal, 28)
    }
}

private struct MessageView: View {
    let icon: String
    let text: String
    let button: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 44))
            Text(text).multilineTextAlignment(.center)
            if let button {
                Button(button, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}
