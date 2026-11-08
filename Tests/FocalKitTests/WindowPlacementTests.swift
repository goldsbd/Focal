import CoreGraphics
import Testing
@testable import FocalKit

// Shaped like the real desk: Dell 40" ultrawide as main (menu bar + Dock), MacBook below, 4K to the right.
private let dell = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 3840, height: 1620),
                                  visibleFrame: CGRect(x: 0, y: 70, width: 3840, height: 1517))
private let laptop = ScreenGeometry(frame: CGRect(x: 1056, y: -1117, width: 1728, height: 1117),
                                    visibleFrame: CGRect(x: 1056, y: -1117, width: 1728, height: 1079))
private let uhd = ScreenGeometry(frame: CGRect(x: 3840, y: 0, width: 1920, height: 1080),
                                 visibleFrame: CGRect(x: 3840, y: 0, width: 1920, height: 1080))
private let chrome: CGFloat = 52
private let minContent = CGSize(width: 360, height: 220)

private func request(_ media: CGSize, policy: PlacementPolicy = .centerOnMainDisplay, pointer: CGPoint = .zero,
                     last: CGRect? = nil, fit: CGFloat = 0.8, upscale: Bool = false) -> PlacementRequest {
    PlacementRequest(mediaSize: media, chromeHeight: chrome, policy: policy, screens: [dell, laptop, uhd],
                     pointer: pointer, lastFrame: last, fitFraction: fit, allowUpscale: upscale, minContentSize: minContent)
}

@Test func contentIsCenteredOnMainDisplay() {
    let p = WindowPlacement.place(request(CGSize(width: 1200, height: 800)))
    #expect(abs(p.contentRect.midX - dell.visibleFrame.midX) <= 0.5)
    #expect(abs(p.contentRect.midY - dell.visibleFrame.midY) <= 0.5)
    #expect(p.contentRect.size == CGSize(width: 1200, height: 800))
    #expect(p.frame.height == 800 + chrome)
    #expect(p.frame.minY == p.contentRect.minY, "title bar sits above the content")
}

@Test func largeImageFitsInsideTheFitFractionWithAspectKept() {
    let media = CGSize(width: 7680, height: 3240)
    let p = WindowPlacement.place(request(media))
    #expect(p.contentRect.width <= dell.visibleFrame.width * 0.8 + 0.5)
    #expect(p.frame.height <= dell.visibleFrame.height * 0.8 + 0.5)
    let aspect = p.contentRect.width / p.contentRect.height
    #expect(abs(aspect - media.width / media.height) / (media.width / media.height) < 0.005)
    #expect(abs(p.contentRect.midX - dell.visibleFrame.midX) <= 0.5)
}

@Test func smallImageIsNotEnlargedUnlessAllowed() {
    let media = CGSize(width: 640, height: 480)
    #expect(WindowPlacement.place(request(media)).contentRect.size == media)
    let up = WindowPlacement.place(request(media, upscale: true)).contentRect.size
    #expect(up.height == (dell.visibleFrame.height * 0.8 - chrome).rounded())
}

@Test func tinyImageGetsTheMinimumWindow() {
    #expect(WindowPlacement.place(request(CGSize(width: 16, height: 16))).contentRect.size == minContent)
}

@Test func pointerPolicyUsesTheDisplayUnderThePointer() {
    let p = WindowPlacement.place(request(CGSize(width: 800, height: 600), policy: .centerOnPointerDisplay,
                                          pointer: CGPoint(x: 4500, y: 500)))
    #expect(abs(p.contentRect.midX - uhd.visibleFrame.midX) <= 0.5)
    #expect(abs(p.contentRect.midY - uhd.visibleFrame.midY) <= 0.5)
    let lost = WindowPlacement.place(request(CGSize(width: 800, height: 600), policy: .centerOnPointerDisplay,
                                             pointer: CGPoint(x: -9000, y: 0)))
    #expect(abs(lost.contentRect.midX - dell.visibleFrame.midX) <= 0.5, "pointer off every display → main")
}

@Test func rememberPolicyReusesTheLastFrame() {
    let last = CGRect(x: 1400, y: 300, width: 1000, height: 700)
    #expect(WindowPlacement.place(request(CGSize(width: 300, height: 300), policy: .rememberLastPosition, last: last)).frame == last)
}

@Test func rememberPolicyFallsBackWhenThatDisplayIsGone() {
    let gone = CGRect(x: 9000, y: 300, width: 1000, height: 700)
    let p = WindowPlacement.place(request(CGSize(width: 1000, height: 700), policy: .rememberLastPosition, last: gone))
    #expect(abs(p.contentRect.midX - dell.visibleFrame.midX) <= 0.5)
}

@Test func frameNeverLeavesTheVisibleArea() {
    let p = WindowPlacement.place(request(CGSize(width: 2000, height: 9000), fit: 1.0))
    #expect(dell.visibleFrame.contains(p.frame))
}

@Test func refitKeepsTheWindowWhereTheUserPutIt() {
    let center = CGPoint(x: 900, y: 700)
    let p = WindowPlacement.refit(mediaSize: CGSize(width: 600, height: 900), chrome: chrome, keepingCenter: center,
                                  in: dell.visibleFrame, fitFraction: 0.8, allowUpscale: false, minContent: minContent)
    #expect(abs(p.contentRect.midX - center.x) <= 0.5)
    #expect(abs(p.contentRect.midY - center.y) <= 0.5)
    #expect(p.contentRect.size == CGSize(width: 600, height: 900))
}

@Test func tallTextKeepsItsWidthAndCapsItsHeight() {
    // 100 columns wide, thousands of lines tall: full width, height capped to the screen share.
    var r = request(CGSize(width: 1044, height: 5000))
    r.preserveAspect = false
    let p = WindowPlacement.place(r)
    #expect(p.contentRect.width == 1044)
    #expect(p.contentRect.height == (dell.visibleFrame.height * 0.8 - chrome).rounded())
    #expect(abs(p.contentRect.midX - dell.visibleFrame.midX) <= 0.5)
}

@Test func stackedWindowsStepDownRightOnlyWhenOverlapping() {
    let p = WindowPlacement.place(request(CGSize(width: 800, height: 600)))
    let moved = WindowPlacement.offsetIfStacked(p, occupied: [p.frame], step: 24, chrome: chrome, in: dell.visibleFrame)
    #expect(moved.frame.origin == CGPoint(x: p.frame.minX + 24, y: p.frame.minY - 24))
    let twice = WindowPlacement.offsetIfStacked(p, occupied: [p.frame, moved.frame], step: 24, chrome: chrome, in: dell.visibleFrame)
    #expect(twice.frame.origin == CGPoint(x: p.frame.minX + 48, y: p.frame.minY - 48))
    let alone = WindowPlacement.offsetIfStacked(p, occupied: [CGRect(x: 0, y: 0, width: 10, height: 10)], step: 24,
                                                chrome: chrome, in: dell.visibleFrame)
    #expect(alone.frame == p.frame)
}
