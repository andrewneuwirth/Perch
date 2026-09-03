import CoreGraphics
import Foundation

/// Pure frame math for the side panel. No AppKit dependency so it can be unit-tested
/// with `swift test` (see Package.swift at the repo root).
enum PanelGeometry {
    enum Side { case left, right }

    struct Frames: Equatable {
        var shown: CGRect
        var hidden: CGRect
    }

    static let minWidth: CGFloat = 400
    static let minHeight: CGFloat = 320
    /// Dragging the top edge to within this distance of the screen top snaps to full height.
    static let fullHeightSnapThreshold: CGFloat = 8

    /// Resolve the on-screen panel height for a given stored height.
    /// - `height` nil = full height. Stored heights include `bottomInset`.
    static func resolvedHeight(visibleFrame: CGRect, height: CGFloat?, bottomInset: CGFloat) -> CGFloat {
        let requested = min(height ?? visibleFrame.height, visibleFrame.height)
        let usable = requested - bottomInset
        let floor = min(minHeight, visibleFrame.height - bottomInset)
        return max(usable, floor)
    }

    /// Shown and hidden (slide-out) frames, bottom-anchored above `bottomInset`.
    static func frames(
        visibleFrame vf: CGRect,
        side: Side,
        width: CGFloat,
        height: CGFloat?,
        bottomInset: CGFloat,
    ) -> Frames {
        let h = resolvedHeight(visibleFrame: vf, height: height, bottomInset: bottomInset)
        let y = vf.minY + bottomInset
        switch side {
        case .right:
            return Frames(
                shown: CGRect(x: vf.maxX - width, y: y, width: width, height: h),
                hidden: CGRect(x: vf.maxX, y: y, width: width, height: h),
            )
        case .left:
            return Frames(
                shown: CGRect(x: vf.minX, y: y, width: width, height: h),
                hidden: CGRect(x: vf.minX - width, y: y, width: width, height: h),
            )
        }
    }

    /// Height to store after a top-edge drag ends. Returns nil when the top edge is
    /// within the snap threshold of the screen top (= full height).
    static func storedHeightAfterDrag(frameTop: CGFloat, frameHeight: CGFloat, visibleFrame vf: CGRect, bottomInset: CGFloat) -> CGFloat? {
        if frameTop >= vf.maxY - fullHeightSnapThreshold { return nil }
        return frameHeight + bottomInset
    }

    /// Clamp a live drag height so the panel never leaves the screen or shrinks below the minimum.
    static func clampedDragHeight(_ proposed: CGFloat, frameMinY: CGFloat, visibleFrame vf: CGRect) -> CGFloat {
        let maxH = vf.maxY - frameMinY
        return min(max(proposed, minHeight), maxH)
    }
}
