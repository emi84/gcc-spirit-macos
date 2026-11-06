// Builds a test card: a grey gradient, text and a filled disc (engraved), and red hairlines (cut):
// a rectangle around everything and a circle. Usage: make_test_pdf out.pdf [scale]
// (scale 1 = 200 x 120 mm; the bundled card uses 0.4 = 80 x 48 mm).
import CoreGraphics
import CoreText
import Foundation

let mm: CGFloat = 72 / 25.4
let k: CGFloat = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 1) : 1
var box = CGRect(x: 0, y: 0, width: 200 * mm * k, height: 120 * mm * k)
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let ctx = CGContext(url, mediaBox: &box, nil)!
ctx.beginPDFPage(nil)
ctx.scaleBy(x: k, y: k)
// Gradient 20…100 mm across, 60 mm tall.
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                      colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.clip(to: CGRect(x: 20 * mm, y: 40 * mm, width: 80 * mm, height: 60 * mm))
ctx.drawLinearGradient(grad, start: CGPoint(x: 20 * mm, y: 0), end: CGPoint(x: 100 * mm, y: 0), options: [])
ctx.restoreGState()
// A black filled star-ish shape.
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 120 * mm, y: 60 * mm, width: 30 * mm, height: 30 * mm))
// Text.
let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 14 * mm, nil)
let attr = NSAttributedString(string: "MARBRE", attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
ctx.textPosition = CGPoint(x: 20 * mm, y: 15 * mm)
CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
// Red hairlines: rectangle 10 mm in from the edges, and a circle.
ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
ctx.setLineWidth(0.1 / k)   // a hairline whatever the scale
ctx.stroke(CGRect(x: 10 * mm, y: 10 * mm, width: 180 * mm, height: 100 * mm))
ctx.strokeEllipse(in: CGRect(x: 155 * mm, y: 20 * mm, width: 25 * mm, height: 25 * mm))
// A thick red line (0.5 mm): engraved, not cut.
ctx.setLineWidth(0.5 * mm)
ctx.move(to: CGPoint(x: 120 * mm, y: 30 * mm)); ctx.addLine(to: CGPoint(x: 150 * mm, y: 30 * mm)); ctx.strokePath()
ctx.endPDFPage()
ctx.closePDF()
