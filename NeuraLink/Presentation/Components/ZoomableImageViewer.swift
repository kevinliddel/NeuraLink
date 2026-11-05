//
//  ZoomableImageViewer.swift
//  NeuraLink
//
//  Full-screen viewer for a still picture, presented with
//  `.zoomableImageViewer(_:)` and a `ViewedPicture`. Like Photos, the
//  picture grows out of the rectangle it was tapped in (its `sourceFrame`,
//  read with a `WindowFrameProbe`) and shrinks back into it on close. In
//  between it is fitted to the screen: pinch or double-tap zooms around the
//  fingers, a drag pans while zoomed, and at normal size a drag up or down
//  pulls it away to close. The journal opens its diary pictures here.
//
//  Created by Dedicatus on 05/11/2026.
//

import SwiftUI
import UIKit

/// A picture handed to `ZoomableImageViewer`.
struct ViewedPicture: Identifiable {
    let id = UUID()
    let image: UIImage
    /// What VoiceOver reads for the picture itself.
    var label = "Picture"
    /// Shown under the picture, e.g. when it was taken.
    var caption: String?
    /// Where the picture sat on screen, in window coordinates; nil
    /// cross-fades instead of zooming.
    var sourceFrame: CGRect?
    /// Corner radius of the picture at `sourceFrame`.
    var sourceCornerRadius: CGFloat = 0
}

extension View {
    /// Presents `ZoomableImageViewer` while `picture` is set. Set it inside
    /// `ZoomableImageViewer.withoutCoverSlide`: the cover then comes and
    /// goes without its slide, and the zoom out of and back into
    /// `sourceFrame` is the only motion.
    func zoomableImageViewer(_ picture: Binding<ViewedPicture?>) -> some View {
        fullScreenCover(item: picture) { item in
            ZoomableImageViewer(picture: item) {
                ZoomableImageViewer.withoutCoverSlide { picture.wrappedValue = nil }
            }
        }
    }
}

struct ZoomableImageViewer: View {
    let picture: ViewedPicture
    /// Removes the cover once the picture is back in its rectangle.
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False while the picture sits in its source rectangle (the first and
    /// last frames), true once it has grown to the screen.
    @State private var isExpanded = false
    @State private var isClosing = false
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// How far a drag at normal size has pulled the picture; past
    /// `closeDistance` vertically it closes the viewer.
    @State private var pull: CGSize = .zero
    /// Last reported values of the gestures in flight (nil when idle), so
    /// each change applies only its delta and a pinch joining a drag (or
    /// ending before it) never makes the picture jump.
    @State private var lastMagnification: CGFloat?
    @State private var lastTranslation: CGSize?

    static let maxScale: CGFloat = 4
    private static let closeDistance: CGFloat = 120
    private static let closeFlick: CGFloat = 320

    /// Runs `change` without the full-screen cover's slide.
    static func withoutCoverSlide(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    var body: some View {
        GeometryReader { proxy in
            stage(in: proxy.size)
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) { topBar.opacity(chromeOpacity) }
        .overlay(alignment: .bottom) { captionLabel.opacity(chromeOpacity) }
        .allowsHitTesting(!isClosing)
        .presentationBackground(.clear)
        .statusBarHidden(isExpanded)
        .accessibilityAction(.escape) { close() }
        .onAppear {
            withAnimation(transitionAnimation) { isExpanded = true }
        }
    }

    // MARK: - Picture

    /// The stack fills the window, so its space is the window's (the
    /// space `sourceFrame` is in) and gesture locations stay in screen
    /// space whatever the current zoom.
    private func stage(in size: CGSize) -> some View {
        let frame = pictureFrame(in: size)
        return ZStack {
            Color.black.opacity(backdropOpacity)
            // Filled into its frame and clipped like the thumbnail, so the
            // first frame matches it exactly; once the frame has the
            // picture's own shape, fill and fit are the same.
            Image(uiImage: picture.image)
                .resizable()
                .scaledToFill()
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .scaleEffect(scale * pullShrink)
                .offset(x: offset.width + pull.width, y: offset.height + pull.height)
                .position(x: frame.midX, y: frame.midY)
                .opacity(zoomsFromSource || isExpanded ? 1 : 0)
                .accessibilityLabel(picture.label)
        }
        .contentShape(Rectangle())
        .gesture(drag(in: size))
        .simultaneousGesture(magnify(in: size))
        .onTapGesture(count: 2) { location in toggleZoom(at: location, in: size) }
    }

    /// Zooms out of the source rectangle unless there is none or the
    /// person asked iOS to reduce motion; then it cross-fades.
    private var zoomsFromSource: Bool {
        picture.sourceFrame != nil && !reduceMotion
    }

    /// The source rectangle before opening and while closing, else the
    /// picture fitted to the screen.
    private func pictureFrame(in size: CGSize) -> CGRect {
        if !isExpanded, zoomsFromSource, let source = picture.sourceFrame {
            return source
        }
        return Self.fittedRect(picture.image.size, in: size)
    }

    private var cornerRadius: CGFloat {
        !isExpanded && zoomsFromSource ? picture.sourceCornerRadius : 0
    }

    private var backdropOpacity: CGFloat {
        isExpanded ? 1 - min(abs(pull.height) / 500, 0.7) : 0
    }

    /// The picture shrinks a little as it is pulled away, as in Photos.
    private var pullShrink: CGFloat {
        1 - min(abs(pull.height) / 1_000, 0.25)
    }

    private var chromeOpacity: CGFloat {
        isExpanded ? 1 - min(abs(pull.height) / Self.closeDistance, 1) : 0
    }

    private var transitionAnimation: Animation {
        zoomsFromSource ? .snappy(duration: 0.38) : .easeInOut(duration: 0.2)
    }

    private var settleAnimation: Animation? {
        reduceMotion ? nil : .snappy
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button {
                close()
            } label: {
                chromeIcon("xmark")
            }
            .accessibilityLabel("Close")
            Spacer()
            ShareLink(
                item: Image(uiImage: picture.image),
                preview: SharePreview(picture.caption ?? picture.label, image: Image(uiImage: picture.image))
            ) {
                chromeIcon("square.and.arrow.up")
            }
            .accessibilityLabel("Share")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func chromeIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .hudGlass(Circle())
    }

    @ViewBuilder
    private var captionLabel: some View {
        if let caption = picture.caption {
            Text(caption)
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .hudGlass(Capsule())
                .padding(.bottom, 12)
        }
    }

    // MARK: - Gestures

    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let previous = lastMagnification ?? 1
                lastMagnification = value.magnification
                let newScale = min(max(scale * value.magnification / previous, 1), Self.maxScale)
                offset = Self.offset(zoomingFrom: scale, to: newScale, around: value.startLocation, offset: offset, in: size)
                scale = newScale
                if pull != .zero { pull = .zero }
            }
            .onEnded { _ in
                lastMagnification = nil
                settle(in: size)
            }
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let previous = lastTranslation ?? .zero
                lastTranslation = value.translation
                let delta = CGSize(
                    width: value.translation.width - previous.width,
                    height: value.translation.height - previous.height)
                if scale > 1 {
                    offset.width += delta.width
                    offset.height += delta.height
                } else if lastMagnification == nil {
                    pull.width += delta.width
                    pull.height += delta.height
                }
            }
            .onEnded { value in
                lastTranslation = nil
                let flung = pull.height + value.predictedEndTranslation.height - value.translation.height
                if scale > 1 {
                    settle(in: size)
                } else if abs(pull.height) > Self.closeDistance || abs(flung) > Self.closeFlick {
                    close()
                } else {
                    withAnimation(settleAnimation) { pull = .zero }
                }
            }
    }

    /// Back to normal size when barely zoomed, else pans the picture back
    /// over the screen edges it was dragged past.
    private func settle(in size: CGSize) {
        withAnimation(settleAnimation) {
            if scale < 1.05 {
                scale = 1
                offset = .zero
            } else {
                offset = Self.clamped(offset, scale: scale, imageSize: picture.image.size, in: size)
            }
        }
    }

    private func toggleZoom(at location: CGPoint, in size: CGSize) {
        withAnimation(settleAnimation) {
            if scale > 1 {
                scale = 1
                offset = .zero
            } else {
                let target = Self.doubleTapScale(imageSize: picture.image.size, in: size)
                let zoomed = Self.offset(zoomingFrom: 1, to: target, around: location, offset: .zero, in: size)
                offset = Self.clamped(zoomed, scale: target, imageSize: picture.image.size, in: size)
                scale = target
            }
        }
    }

    /// Shrinks the picture back into its source rectangle from wherever
    /// it is (zoomed, panned or mid-pull), then removes the cover.
    private func close() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(transitionAnimation, completionCriteria: .logicallyComplete) {
            isExpanded = false
            scale = 1
            offset = .zero
            pull = .zero
        } completion: {
            onClose()
        }
    }

    // MARK: - Geometry

    /// The offset that keeps the content under `anchor` still while the
    /// scale goes `from` → `to`. Scale and offset both apply around the
    /// container's centre.
    static func offset(zoomingFrom from: CGFloat, to: CGFloat, around anchor: CGPoint, offset: CGSize, in container: CGSize) -> CGSize {
        let ratio = to / from
        let dx = anchor.x - container.width / 2
        let dy = anchor.y - container.height / 2
        return CGSize(width: dx - ratio * (dx - offset.width), height: dy - ratio * (dy - offset.height))
    }

    /// Pans no further than the zoomed picture overflows the container on
    /// each axis, so no empty band opens at an edge; an axis that still fits
    /// stays centred.
    static func clamped(_ offset: CGSize, scale: CGFloat, imageSize: CGSize, in container: CGSize) -> CGSize {
        let fitted = fittedSize(imageSize, in: container)
        let maxX = max(0, (fitted.width * scale - container.width) / 2)
        let maxY = max(0, (fitted.height * scale - container.height) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }

    /// Double tap fills the screen (a landscape picture on a portrait
    /// phone fills its height), at least 2× and at most `maxScale`.
    static func doubleTapScale(imageSize: CGSize, in container: CGSize) -> CGFloat {
        let fitted = fittedSize(imageSize, in: container)
        guard fitted.width > 0, fitted.height > 0 else { return 2 }
        let fill = max(container.width / fitted.width, container.height / fitted.height)
        return min(max(fill, 2), maxScale)
    }

    static func fittedSize(_ imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return container }
        let fit = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
    }

    /// The fitted picture centred in the container.
    static func fittedRect(_ imageSize: CGSize, in container: CGSize) -> CGRect {
        let fitted = fittedSize(imageSize, in: container)
        return CGRect(
            x: (container.width - fitted.width) / 2,
            y: (container.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height)
    }
}

// MARK: - Source frame

/// Reads where a view sits in its window, on demand. The tapped thumbnail
/// and the viewer live in different presentations (the journal is a
/// sheet, the viewer a full-screen cover), so the rectangle is read in
/// UIKit window coordinates, the one space both share.
final class WindowFrameProbe {
    fileprivate weak var view: UIView?

    /// The probed view's frame in window coordinates; nil until it is in a
    /// window.
    var frame: CGRect? {
        guard let view, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }
}

extension View {
    /// Lets `probe` report this view's window frame.
    func windowFrameProbe(_ probe: WindowFrameProbe) -> some View {
        background(WindowFrameProbeView(probe: probe))
    }
}

private struct WindowFrameProbeView: UIViewRepresentable {
    let probe: WindowFrameProbe

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        probe.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        probe.view = uiView
    }
}

#Preview {
    ZoomableImageViewer(
        picture: ViewedPicture(image: UIImage(systemName: "photo") ?? UIImage(), caption: "Tue, Oct 20 at 8:38 pm"),
        onClose: {})
}
