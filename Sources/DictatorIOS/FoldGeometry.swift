import SwiftUI

/// Where a partly folded iPhone Duo's crease is, for layouts that step
/// around it. Shared by the app's `AdaptiveColumns` and the keyboard
/// extension (which compiles this file by path, see project.yml).
enum FoldGeometry {
    /// The horizontal span of an active vertical fold, in the proxy's
    /// coordinates, if the device is partly folded. `.division` regions are
    /// only active then (flat, the list is empty), so a flat Duo returns nil:
    /// an invisible crease is not an edge to lay out around. `.occlusion` is
    /// the camera and is the safe area's job.
    static func verticalFold(in proxy: GeometryProxy) -> ClosedRange<CGFloat>? {
        if #available(iOS 27.1, *) {
            let bounds = CGRect(origin: .zero, size: proxy.size)
            for region in proxy.reservedRegions(kind: .division) where region.isActive {
                let frame = region.frame.intersection(bounds)
                guard !frame.isNull, frame.height > frame.width else { continue }
                return frame.minX...frame.maxX
            }
            // TODO(fold): a horizontal fold (the device turned so the crease
            // runs across the screen) isn't stepped around yet: the columns
            // run top to bottom across it. ArrangementView with
            // `.arrangementViewStyle(.split.axes(.vertical))` looks like the
            // route, but it can't be exercised partly folded in the
            // simulator, so it's left until it can be checked on a device.
        }
        return nil
    }
}
