import CoreGraphics
import Testing
@testable import FocalKit

private let size = CGSize(width: 100, height: 60)

@Test func clockwiseRotationMovesCornersTheRightWay() {
    // Top-left → top-right, bottom-left → top-left of the new (60 × 100) image.
    #expect(Geometry.rotate(CGPoint(x: 0, y: 0), clockwise: true, imageSize: size) == CGPoint(x: 60, y: 0))
    #expect(Geometry.rotate(CGPoint(x: 0, y: 60), clockwise: true, imageSize: size) == CGPoint(x: 0, y: 0))
    #expect(Geometry.rotate(CGPoint(x: 100, y: 0), clockwise: true, imageSize: size) == CGPoint(x: 60, y: 100))
}

@Test func counterClockwiseUndoesClockwise() {
    let p = CGPoint(x: 13, y: 47)
    let cw = Geometry.rotate(p, clockwise: true, imageSize: size)
    #expect(Geometry.rotate(cw, clockwise: false, imageSize: CGSize(width: size.height, height: size.width)) == p)
}

@Test func rectRotationStaysNormalized() {
    let r = Geometry.rotate(CGRect(x: 10, y: 5, width: 30, height: 20), clockwise: true, imageSize: size)
    #expect(r == CGRect(x: 35, y: 10, width: 20, height: 30))
}

@Test func lineHitTestingUsesStrokeDistance() {
    let line = Annotation(kind: .line, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], color: .red, lineWidth: 4)
    #expect(line.hitTest(CGPoint(x: 50, y: 5), tolerance: 4))
    #expect(!line.hitTest(CGPoint(x: 50, y: 12), tolerance: 4))
}

@Test func rectangleHitsOnItsEdgeNotItsMiddle() {
    let box = Annotation(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 90)], color: .red, lineWidth: 4)
    #expect(box.hitTest(CGPoint(x: 11, y: 50), tolerance: 3))
    #expect(!box.hitTest(CGPoint(x: 60, y: 50), tolerance: 3))
    let redact = Annotation(kind: .redact, points: box.points, color: .black, lineWidth: 0)
    #expect(redact.hitTest(CGPoint(x: 60, y: 50), tolerance: 3))
}

@Test func ellipseHitsNearItsOutline() {
    let e = Annotation(kind: .ellipse, points: [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 100)], color: .red, lineWidth: 4)
    #expect(e.hitTest(CGPoint(x: 200, y: 50), tolerance: 3))
    #expect(!e.hitTest(CGPoint(x: 100, y: 50), tolerance: 3))
}

@Test func draggingACornerKeepsTheOppositeCorner() {
    let box = Annotation(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 40)], color: .red, lineWidth: 2)
    let moved = box.movingHandle(2, to: CGPoint(x: 80, y: 70))   // bottom-right
    #expect(moved.rect == CGRect(x: 10, y: 10, width: 70, height: 60))
    #expect(box.anchor(forHandle: 2) == CGPoint(x: 10, y: 10))
}

@Test func shiftConstraintsSnap() {
    let a = CGPoint(x: 0, y: 0)
    let snapped = Geometry.constrain45(from: a, to: CGPoint(x: 100, y: 10))
    #expect(abs(snapped.y) < 0.001)
    #expect(Geometry.constrainSquare(from: a, to: CGPoint(x: -30, y: 10)) == CGPoint(x: -30, y: 30))
}

@Test func textRotatesAroundItsCenter() {
    let t = Annotation(kind: .text, points: [CGPoint(x: 10, y: 10)], color: .red, lineWidth: 0, text: "Hi", fontSize: 20)
    let s = t.textSize
    let r = t.rotated(clockwise: true, imageSize: size)
    let oldCenter = CGPoint(x: 10 + s.width / 2, y: 10 + s.height / 2)
    let expected = Geometry.rotate(oldCenter, clockwise: true, imageSize: size)
    #expect(abs(r.points[0].x + s.width / 2 - expected.x) < 0.001)
    #expect(abs(r.points[0].y + s.height / 2 - expected.y) < 0.001)
}
