import QuartzCore
import SwiftUI
import UIKit

struct ViewfinderGestures: UIViewRepresentable {
    var onTap: (CGPoint) -> Void
    var onLongPress: (CGPoint) -> Void
    var canPan: () -> Bool
    var onPan: (CGFloat, Bool) -> Void
    var onPinch: (CGFloat, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        coordinator.parent = self

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))

        for recognizer in [tap, longPress, pan, pinch] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ViewfinderGestures?
        private var longPressAt: CFTimeInterval = 0

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view, CACurrentMediaTime() - longPressAt > 0.8 else { return }
            parent?.onTap(normalized(recognizer.location(in: view), in: view))
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view else { return }
            longPressAt = CACurrentMediaTime()
            parent?.onLongPress(normalized(recognizer.location(in: view), in: view))
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let ended = recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
            parent?.onPan(recognizer.translation(in: view).y, ended)
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            let ended = recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
            parent?.onPinch(recognizer.scale, ended)
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            if recognizer is UIPanGestureRecognizer {
                return parent?.canPan() ?? false
            }
            return true
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            recognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
        }

        private func normalized(_ point: CGPoint, in view: UIView) -> CGPoint {
            CGPoint(x: point.x / max(view.bounds.width, 1), y: point.y / max(view.bounds.height, 1))
        }
    }
}

struct FocusMarkerView: View {
    let marker: FocusMarker
    let bias: Float
    let adjusting: Bool
    let size: CGSize

    var body: some View {
        let p = CGPoint(x: marker.point.x * size.width, y: marker.point.y * size.height)
        let side: CGFloat = 76
        let sunX = p.x + side / 2 + 18 > size.width - 12 ? p.x - side / 2 - 18 : p.x + side / 2 + 18
        let sunY = p.y - CGFloat(bias) * 34

        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: side, height: side)
                .position(p)
            if adjusting {
                Capsule()
                    .fill(Color.yellow.opacity(0.7))
                    .frame(width: 1.5, height: 140)
                    .position(x: sunX, y: p.y)
            }
            Image(systemName: "sun.max.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.yellow)
                .position(x: sunX, y: sunY)
            if adjusting || bias != 0 {
                Text(String(format: "%+.1f", bias))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.yellow)
                    .position(x: sunX, y: sunY - 20)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
        .allowsHitTesting(false)
    }
}
