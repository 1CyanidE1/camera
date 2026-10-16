import SwiftUI
import UIKit

struct AssistLayer: UIViewRepresentable {
    let pipeline: CameraPipeline

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.layer.contentsGravity = .resize
        pipeline.assistSink = { [weak view] image in view?.layer.contents = image }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

struct LoupeView: UIViewRepresentable {
    let pipeline: CameraPipeline

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .black
        view.layer.contentsGravity = .resizeAspectFill
        view.layer.magnificationFilter = .linear
        view.layer.cornerRadius = 75
        view.layer.masksToBounds = true
        view.layer.borderColor = UIColor.systemYellow.cgColor
        view.layer.borderWidth = 2
        pipeline.loupeSink = { [weak view] image in view?.layer.contents = image }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

struct HistogramView: View {
    let bins: [UInt8]

    var body: some View {
        Canvas { ctx, size in
            guard !bins.isEmpty else { return }
            let w = size.width / CGFloat(bins.count)
            var path = Path()
            for (i, v) in bins.enumerated() {
                let h = size.height * CGFloat(v) / 255
                path.addRect(CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(w - 0.5, 0.5), height: h))
            }
            ctx.fill(path, with: .color(.white.opacity(0.8)))
        }
        .frame(width: 96, height: 40)
        .padding(4)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }
}

struct ControlRow: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var live: LiveState

    var body: some View {
        HStack(spacing: 12) {
            switch model.editing {
            case .focus:
                Text("близко").font(.caption2).foregroundStyle(.white.opacity(0.7))
                Slider(value: Binding(get: { model.lensPosition }, set: { model.setLens($0) }),
                       in: 0...1,
                       onEditingChanged: { model.lensEditing($0) })
                Text("∞").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            case .iso:
                Text("ISO").font(.caption2.weight(.bold)).foregroundStyle(.yellow)
                Slider(value: Binding(get: { model.isoPosition }, set: { model.setISOPosition($0) }), in: 0...1)
                Text("\(Int(live.overlay.readout.iso.rounded()))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44)
                autoButton
            case .shutter:
                Image(systemName: "timer").font(.caption).foregroundStyle(.yellow)
                Slider(value: Binding(get: { model.shutterPosition }, set: { model.setShutterPosition($0) }), in: 0...1)
                Text(ProBar.shutter(live.overlay.readout.duration))
                    .font(.caption.monospacedDigit())
                    .frame(width: 52)
                autoButton
            case nil:
                EmptyView()
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { model.editing = nil }
            } label: {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.14), in: Circle())
            }
        }
        .tint(.yellow)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private var autoButton: some View {
        Button {
            model.autoExposure()
        } label: {
            Text("A")
                .font(.caption.weight(.bold))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.14), in: Circle())
        }
    }
}

struct ProBar: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var live: LiveState

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(modes) { mode in
                    Button {
                        model.focusMode = mode
                    } label: {
                        Text(mode.title)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(model.focusMode == mode ? Color.black : Color.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(model.focusMode == mode ? Color.yellow : Color.clear, in: Capsule())
                    }
                }
            }
            .padding(2)
            .background(.white.opacity(0.1), in: Capsule())
            Spacer(minLength: 0)
            let r = live.overlay.readout
            if r.iso > 0 {
                chip("ISO \(Int(r.iso.rounded()))", active: model.editing == .iso, manual: r.manualExposure) {
                    model.edit(.iso)
                }
                chip(Self.shutter(r.duration), active: model.editing == .shutter, manual: r.manualExposure) {
                    model.edit(.shutter)
                }
                Text(String(format: "%+.1f", r.bias))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
    }

    private var modes: [FocusMode] {
        FocusMode.allCases.filter { $0 != .manual || (model.info?.limits.supportsManualFocus ?? false) }
    }

    private func chip(_ text: String, active: Bool, manual: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(manual ? Color.yellow : Color.white.opacity(0.85))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.white.opacity(active ? 0.22 : 0.08), in: Capsule())
        }
    }

    static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        if seconds >= 0.95 { return String(format: "%.1f\"", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }
}
