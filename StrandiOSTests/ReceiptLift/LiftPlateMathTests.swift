import Testing
@testable import ReceiptLiftFeature

@Suite("Lift plate math")
struct LiftPlateMathTests {
  @Test("Reachable totals reconstruct exactly", arguments: Array(stride(from: 45.0, through: 1_000.0, by: 5.0)))
  func reachableTotalReconstructs(target: Double) {
    let solution = LiftPlateMath.solve(target: target)

    #expect(solution.exact)
    #expect(solution.nearestBelow == nil)
    #expect(solution.nearestAbove == nil)
    #expect(solution.perSide == solution.perSide.sorted(by: >))
    #expect(abs(45 + 2 * solution.perSide.reduce(0, +) - target) < 0.001)
  }

  @Test("Known totals use the expected heaviest-first plates", arguments: [
    (45.0, []),
    (95.0, [25.0]),
    (135.0, [45.0]),
    (185.0, [45.0, 25.0]),
    (225.0, [45.0, 45.0]),
    (275.0, [45.0, 45.0, 25.0]),
    (315.0, [45.0, 45.0, 45.0])
  ])
  func knownBreakdown(target: Double, expectedPerSide: [Double]) {
    #expect(LiftPlateMath.solve(target: target).perSide == expectedPerSide)
  }

  @Test("The bare bar is an exact empty breakdown")
  func bareBar() {
    let solution = LiftPlateMath.solve(target: 45)

    #expect(solution == .init(perSide: [], exact: true, nearestBelow: nil, nearestAbove: nil))
  }

  @Test("Below-bar targets point upward to the bare bar", arguments: [-20.0, 0.0, 40.0, 44.999])
  func belowBar(target: Double) {
    let solution = LiftPlateMath.solve(target: target)

    #expect(!solution.exact)
    #expect(solution.perSide.isEmpty)
    #expect(solution.nearestBelow == nil)
    #expect(solution.nearestAbove == 45)
  }

  @Test("Unrepresentable totals return exact loadable neighbors", arguments: [
    (46.0, 45.0, 50.0),
    (152.5, 150.0, 155.0),
    (187.0, 185.0, 190.0),
    (187.5, 185.0, 190.0)
  ])
  func unrepresentableTarget(target: Double, expectedBelow: Double, expectedAbove: Double) {
    let solution = LiftPlateMath.solve(target: target)

    #expect(!solution.exact)
    #expect(solution.perSide.isEmpty)
    #expect(solution.nearestBelow == expectedBelow)
    #expect(solution.nearestAbove == expectedAbove)
    #expect(LiftPlateMath.solve(target: expectedBelow).exact)
    #expect(LiftPlateMath.solve(target: expectedAbove).exact)
  }

  @Test("Floating-point noise around an exact total is tolerated")
  func floatingPointSafety() {
    let solution = LiftPlateMath.solve(target: 190.000_000_1)

    #expect(solution.exact)
    #expect(solution.perSide == [45, 25, 2.5])
  }

  @Test("Custom denominations do not need to be multiples of the smallest plate")
  func customDenominations() {
    let exact = LiftPlateMath.solve(target: 135, plates: [45, 25])
    let inexact = LiftPlateMath.solve(target: 140, plates: [45, 25])

    #expect(exact == .init(perSide: [45], exact: true, nearestBelow: nil, nearestAbove: nil))
    #expect(inexact == .init(perSide: [], exact: false, nearestBelow: 135, nearestAbove: 145))
  }
}
