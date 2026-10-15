import SwiftUI

extension View {
    /// Touch reading for a chart inside a scroll view: a tap picks the point under the finger (a second tap
    /// on the same spot clears it), and a sideways slide scrubs along the chart. The slide only begins when
    /// the finger moves mostly sideways, so a vertical swipe that starts on the chart still scrolls the
    /// page. `x` is in the view's own space.
    ///
    /// From iOS 18 any SwiftUI `DragGesture` inside a `ScrollView`, simultaneous or not, stops the page
    /// from scrolling when the swipe starts on it. There the slide is a UIKit pan recognizer that declines
    /// to begin on a vertical movement (`HorizontalScrubPan`); iOS 17 keeps the SwiftUI drag.
    ///
    /// iOS only. macOS keeps its pointer hover (`onContinuousHover`), so this is a no-op there.
    func touchScrub(x: Binding<CGFloat?>) -> some View {
        #if os(iOS)
        modifier(TouchScrubModifier(x: x))
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct TouchScrubModifier: ViewModifier {
    @Binding var x: CGFloat?
    /// Decided on a drag's first movement: true scrubs, false leaves the drag to the scroll view.
    @State private var scrubbing: Bool?

    /// A tap this close to the current selection clears it instead of moving it.
    private static let clearRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                set(x.map { abs($0 - location.x) < Self.clearRadius } == true ? nil : location.x)
            }
            .modifier(SlideGesture(onSlide: set, scrubbing: $scrubbing))
    }

    /// Without animation: an animated update makes the readout trail the finger.
    private func set(_ value: CGFloat?) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { x = value }
    }
}

/// The sideways slide: a direction-gated UIKit pan on iOS 18 and later, the SwiftUI drag before that.
private struct SlideGesture: ViewModifier {
    let onSlide: (CGFloat?) -> Void
    @Binding var scrubbing: Bool?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(HorizontalScrubPan(onSlide: { onSlide($0) }))
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .onChanged { value in
                        if scrubbing == nil {
                            scrubbing = abs(value.translation.width) > abs(value.translation.height)
                        }
                        if scrubbing == true { onSlide(value.location.x) }
                    }
                    .onEnded { _ in scrubbing = nil }
            )
        }
    }
}

/// A pan that begins only when the finger's first movement is more sideways than vertical. Declining a
/// vertical start leaves the touch to the enclosing scroll view, which a SwiftUI drag no longer does.
@available(iOS 18.0, *)
private struct HorizontalScrubPan: UIGestureRecognizerRepresentable {
    let onSlide: (CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onSlide(context.converter.localLocation.x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            // The distance moved so far decides; the speed only when nothing has moved yet.
            let t = pan.translation(in: pan.view)
            let d = (t == .zero) ? pan.velocity(in: pan.view) : t
            return abs(d.x) > abs(d.y)
        }
    }
}
#endif
