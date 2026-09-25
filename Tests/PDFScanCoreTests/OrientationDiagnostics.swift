import CoreGraphics
import ImageIO
import Vision
import XCTest
@testable import PDFScanCore

/// Temporär: gibt aus, was Vision bei kopfstehendem Text liefert.
final class OrientationDiagnostics: XCTestCase {
    func testPrintScores() throws {
        let upright = PipelineTests().makePageForDiagnostics()
        let flipped = ImageOps.rotated(upright, clockwiseDegrees: 180)!
        for (name, image) in [("upright", upright), ("flipped", flipped)] {
            for (oname, o) in [("up", CGImagePropertyOrientation.up), ("down", .down)] {
                for fast in [true, false] {
                    let lines = try TextRecognizer.recognize(image, languages: fast ? [] : ["de-DE"], orientation: o, fast: fast)
                    let conf = lines.map { Double($0.confidence) }
                    let avg = conf.isEmpty ? 0 : conf.reduce(0, +) / Double(conf.count)
                    let score = lines.reduce(0) { $0 + TextRecognizer.plausibility(of: $1) }
                    let sample = lines.prefix(3).map(\.text).joined(separator: " | ")
                    let boxes = lines.prefix(2).map { "\($0.box)" }.joined(separator: " ")
                    print("DIAG \(name) o=\(oname) fast=\(fast) n=\(lines.count) avg=\(String(format: "%.2f", avg)) score=\(Int(score)) :: \(sample) :: \(boxes)")
                }
            }
        }
    }
}
