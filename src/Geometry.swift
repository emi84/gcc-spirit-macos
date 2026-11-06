// The page as it is to be engraved: its size and the transform from the PDF's user space,
// applying the page's own rotation (/Rotate, which drawPDFPage ignores) and any extra quarter
// turn asked for. Origin bottom-left, in points; x along the machine's X axis.

import CoreGraphics

struct PageGeometry {
    let size: CGSize
    let transform: CGAffineTransform

    /// `extra`: clockwise quarter turns on top of the page's own /Rotate (0, 90, 180, 270).
    init(page: CGPDFPage, extra: Int = 0) {
        let b = page.getBoxRect(.mediaBox)
        let angle = ((Int(page.rotationAngle) + extra) % 360 + 360) % 360
        let w = b.width, h = b.height
        // Move the box to the origin, then turn it clockwise by `angle`.
        let toOrigin = CGAffineTransform(translationX: -b.minX, y: -b.minY)
        let turn: CGAffineTransform
        switch angle {
        case 90: turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 180: turn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: turn = .identity
        }
        transform = toOrigin.concatenating(turn)
        size = angle % 180 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
    }
}
