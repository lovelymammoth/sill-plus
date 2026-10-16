import Foundation
import CoreGraphics

// Where the picture sits in the stream view, and where a point of the view lands on the Mac
// (docs/mac-client.md, "Pointer and scrolling"). The view shows the frame aspect-fit, the way
// AVSampleBufferDisplayLayer's .resizeAspect does: as large as it fits, centred, with bars on the two
// sides the frame does not reach. Input travels as fractions of the streamed frame (Input.swift: 0…1
// across its width and height, whatever size the client draws it at), so a point is taken into the
// picture's rectangle and divided by its size.
//
// Pure: Foundation and CoreGraphics only, checked with swiftc (Tests/checks/mac-client-keys).

enum StreamGeometry {
    /// The frame's rectangle inside `bounds`, aspect-fit and centred; `bounds` itself while the frame's
    /// size is unknown or empty.
    static func pictureRect(frame: CGSize, in bounds: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / frame.width, bounds.height / frame.height)
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// A point of the view as fractions of the frame, x to the right and y down from the frame's top
    /// edge (the wire's direction). `flipped` says whether the view's y already grows downward (an
    /// NSView with isFlipped); an AppKit default view's y grows upward. Clamped to 0…1, so a drag that
    /// leaves the picture keeps pressing at its edge, as the iOS client's does. Nil while the picture
    /// has no size.
    static func fraction(of point: CGPoint, picture: CGRect, flipped: Bool) -> (x: Double, y: Double)? {
        guard picture.width > 0, picture.height > 0 else { return nil }
        var x = (point.x - picture.minX) / picture.width
        var y = (point.y - picture.minY) / picture.height
        if !flipped { y = 1 - y }
        x = min(max(x, 0), 1)
        y = min(max(y, 0), 1)
        return (Double(x), Double(y))
    }

    /// Whether a point of the view is on the picture (not on a bar beside it).
    static func isOnPicture(_ point: CGPoint, picture: CGRect) -> Bool {
        picture.contains(point)
    }

    /// A scroll as fractions of the frame (Input.swift: the distance the content should move,
    /// positive dy moving it down). `dx`, `dy` are NSEvent's scrollingDelta in points, which already
    /// follow this Mac's own scroll direction setting (natural or not), so they pass with their sign;
    /// a wheel without precise deltas counts lines, each `lineHeight` points. Nil while the picture
    /// has no size.
    static func scrollFraction(dx: Double, dy: Double, precise: Bool, picture: CGRect,
                               lineHeight: Double = 12) -> (dx: Double, dy: Double)? {
        guard picture.width > 0, picture.height > 0 else { return nil }
        let k = precise ? 1.0 : lineHeight
        return (dx * k / Double(picture.width), dy * k / Double(picture.height))
    }

    /// The Viewport this client sends (Viewport.swift): the picture area in points, the view's size,
    /// rounded to whole points, at least 1. The client never asks the Mac to resize windows (scale
    /// nil) unless the user chose a scale.
    static func viewportSize(_ bounds: CGSize) -> (width: Double, height: Double) {
        (max(1, Double(bounds.width.rounded())), max(1, Double(bounds.height.rounded())))
    }
}
