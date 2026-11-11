import SwiftUI

/// How the shelf icon is drawn: a dark storage pouch with a few white sheets showing above its top edge
/// (reference image chosen 2026-08-16).
///
/// **Vector-drawn, not a bitmap.** First, all four size tiers must stay sharp; second, the reference is a
/// render of unknown origin, and this project is a publicly released GPL app that cannot ship someone else's
/// icon assets. So this redraws the structure of that image: back plate + three sheets + front pouch, with
/// all proportions normalized to the side length, so resizing needs no retuning.
///
/// The size is given by the caller (`ChipPillMetrics.bareIconVisibleSlot`) and the art fills the whole
/// canvas; the transparent margin around it is the job of the caller's slot, matching Apple's icon assets.
struct ShelfTrayArt: View {
    let size: CGFloat
    /// Brightens as a whole when an external file is dragged over the cell.
    var lifted: Bool = false

    var body: some View {
        ZStack {
            backPlate
            papers
            frontPocket
        }
        .frame(width: size, height: size)
        .brightness(lifted ? 0.08 : 0)
    }

    // MARK: Back plate

    private var backPlate: some View {
        RoundedRectangle(cornerRadius: size * 0.215, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(white: 0.30), Color(white: 0.19)],
                startPoint: .top,
                endPoint: .bottom
            ))
    }

    // MARK: Sheets

    /// Three white sheets, the middle one tallest, the side ones slightly shorter and tilted outward: the fan
    /// in the reference image. Drawn within the back plate's bounds and clipped as a whole, so the tilted
    /// corners do not poke out of the rounded corners.
    private var papers: some View {
        ZStack {
            paper(offsetX: -0.085, offsetY: 0.010, rotation: -7, scale: 0.94)
            paper(offsetX: 0.085, offsetY: 0.020, rotation: 7, scale: 0.94)
            paper(offsetX: 0, offsetY: -0.005, rotation: 0, scale: 1)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.215, style: .continuous))
    }

    private func paper(offsetX: CGFloat, offsetY: CGFloat, rotation: Double, scale: CGFloat) -> some View {
        let width = size * 0.46 * scale
        let height = size * 0.56 * scale
        return RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(white: 0.99), Color(white: 0.90)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .frame(width: width, height: height)
            .rotationEffect(.degrees(rotation))
            // The lower half of the sheets is covered by the front pouch, so they are shifted up as a whole:
            // only the top edge shows.
            .offset(x: size * offsetX, y: size * (offsetY - 0.10))
    }

    // MARK: Front pouch

    /// The front pouch is a translucent dark gray; its top edge is the reference image's curve that is "high
    /// on the left, low on the right, then pulls back". Translucency is the key: the sheets show through
    /// slightly from behind, which gives the "inside a pouch" depth.
    private var frontPocket: some View {
        PocketShape()
            .fill(LinearGradient(
                colors: [Color(white: 0.46).opacity(0.94), Color(white: 0.22).opacity(0.97)],
                startPoint: .topLeading,
                endPoint: .bottom
            ))
            .frame(width: size, height: size)
    }
}

/// Front pouch outline. All control points are normalized coordinates (0…1 times the side length), placed to
/// follow the reference image.
private struct PocketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + w * x, y: rect.minY + h * y) }

        let radius = w * 0.19
        var path = Path()
        // Start at the top left and go right along the top edge: gentle first, then dipping, then pulling
        // back slightly at the right.
        path.move(to: p(0.045, 0.345))
        path.addCurve(to: p(0.52, 0.395), control1: p(0.20, 0.300), control2: p(0.36, 0.345))
        path.addCurve(to: p(0.955, 0.455), control1: p(0.68, 0.445), control2: p(0.83, 0.505))
        // Down the right side -> bottom rounded corners -> back up the left side to the start.
        path.addLine(to: p(0.955, 0.80))
        path.addQuadCurve(to: p(0.955 - radius / w, 0.955), control: p(0.955, 0.955))
        path.addLine(to: p(0.045 + radius / w, 0.955))
        path.addQuadCurve(to: p(0.045, 0.80), control: p(0.045, 0.955))
        path.closeSubpath()
        return path
    }
}
