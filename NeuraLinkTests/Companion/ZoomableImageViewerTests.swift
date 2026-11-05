//
//  ZoomableImageViewerTests.swift
//  NeuraLinkTests
//
//  Full-screen picture viewer behind the journal's diary pictures
//  (docs/Companion/LIVING_COMPANION.md): the picture grows to a centred fit,
//  zooming keeps the content under the fingers still, panning never opens
//  an empty band at an edge, and a double tap fills the screen within the
//  zoom limit.
//

import CoreGraphics
import Testing

@testable import NeuraLink

@MainActor
@Suite("Zoomable image viewer")
struct ZoomableImageViewerTests {

    private let phone = CGSize(width: 390, height: 844)

    @Test("A centred zoom leaves the offset alone")
    func centredZoom() {
        let offset = ZoomableImageViewer.offset(
            zoomingFrom: 1, to: 2, around: CGPoint(x: 195, y: 422), offset: .zero, in: phone)
        #expect(offset == .zero)
    }

    @Test("The point under the fingers stays put through a zoom")
    func anchorStaysStill() {
        let anchor = CGPoint(x: 300, y: 200)
        let start = CGSize(width: 10, height: -20)
        let end = ZoomableImageViewer.offset(zoomingFrom: 1.5, to: 3, around: anchor, offset: start, in: phone)
        // Screen = centre + offset + scale · content; solve the content point
        // before the zoom and project it again after.
        let centre = CGPoint(x: phone.width / 2, y: phone.height / 2)
        let contentX = (anchor.x - centre.x - start.width) / 1.5
        let contentY = (anchor.y - centre.y - start.height) / 1.5
        #expect(abs(centre.x + end.width + 3 * contentX - anchor.x) < 0.001)
        #expect(abs(centre.y + end.height + 3 * contentY - anchor.y) < 0.001)
    }

    @Test("Pans stop where the zoomed picture meets the screen edge")
    func panClamp() {
        // A portrait capture the shape of the screen: at 2× it overflows by
        // half the screen on each axis.
        let image = CGSize(width: 590, height: 1280)
        let fitted = ZoomableImageViewer.fittedSize(image, in: phone)
        let clamped = ZoomableImageViewer.clamped(
            CGSize(width: 5_000, height: -5_000), scale: 2, imageSize: image, in: phone)
        #expect(abs(clamped.width - (fitted.width * 2 - phone.width) / 2) < 0.001)
        #expect(abs(clamped.height + (fitted.height * 2 - phone.height) / 2) < 0.001)
    }

    @Test("An axis that still fits after zooming stays centred")
    func fittingAxisStaysCentred() {
        let landscape = CGSize(width: 1280, height: 720)
        let clamped = ZoomableImageViewer.clamped(
            CGSize(width: 40, height: 300), scale: 2, imageSize: landscape, in: phone)
        #expect(clamped.width == 40)
        #expect(clamped.height == 0)
    }

    @Test("Double tap fills the screen, at least 2× and within the limit")
    func doubleTapScale() {
        let portrait = CGSize(width: 590, height: 1280)
        #expect(ZoomableImageViewer.doubleTapScale(imageSize: portrait, in: phone) == 2)

        // 4:3 landscape: filling the height needs about 2.9×.
        let landscape = CGSize(width: 1280, height: 960)
        let fill = ZoomableImageViewer.doubleTapScale(imageSize: landscape, in: phone)
        #expect(abs(fill - 844 / (390.0 * 960 / 1280)) < 0.001)

        let panorama = CGSize(width: 1280, height: 200)
        #expect(ZoomableImageViewer.doubleTapScale(imageSize: panorama, in: phone) == ZoomableImageViewer.maxScale)
    }

    @Test("The open picture is fitted and centred, the frame it grows to from its thumbnail")
    func fittedRect() {
        let landscape = CGSize(width: 1280, height: 720)
        let rect = ZoomableImageViewer.fittedRect(landscape, in: phone)
        #expect(abs(rect.width - 390) < 0.001)
        #expect(abs(rect.height - 390 * 720 / 1280) < 0.001)
        #expect(abs(rect.midX - phone.width / 2) < 0.001)
        #expect(abs(rect.midY - phone.height / 2) < 0.001)
    }

    @Test("A degenerate image size falls back to the container")
    func degenerateImage() {
        #expect(ZoomableImageViewer.fittedSize(.zero, in: phone) == phone)
        #expect(ZoomableImageViewer.doubleTapScale(imageSize: .zero, in: phone) == 2)
    }
}
