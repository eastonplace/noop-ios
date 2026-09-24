import Foundation

enum LiftPlateMath {
  struct PlateSolution: Equatable, Sendable {
    let perSide: [Double]
    let exact: Bool
    let nearestBelow: Double?
    let nearestAbove: Double?
  }

  nonisolated static func solve(
    target: Double,
    bar: Double = 45,
    plates: [Double] = [45, 35, 25, 10, 5, 2.5]
  ) -> PlateSolution {
    let epsilon = 0.001
    let scale = 1_000.0
    guard target.isFinite, bar.isFinite, bar >= 0 else {
      return PlateSolution(perSide: [], exact: false, nearestBelow: nil, nearestAbove: nil)
    }
    guard target >= bar else {
      return PlateSolution(perSide: [], exact: false, nearestBelow: nil, nearestAbove: bar)
    }
    if abs(target - bar) <= epsilon {
      return PlateSolution(perSide: [], exact: true, nearestBelow: nil, nearestAbove: nil)
    }

    func scaledInteger(_ value: Double) -> Int? {
      let scaled = value * scale
      guard scaled.isFinite, scaled >= 0, scaled <= Double(Int.max) else { return nil }
      return Int(scaled.rounded())
    }

    var availablePlates: [(value: Double, scaled: Int)] = []
    for plate in plates.filter({ $0.isFinite && $0 > 0 }).sorted(by: >) {
      guard let scaled = scaledInteger(plate), scaled > 0,
            !availablePlates.contains(where: { $0.scaled == scaled })
      else { continue }
      availablePlates.append((value: Double(scaled) / scale, scaled: scaled))
    }
    guard !availablePlates.isEmpty else {
      return PlateSolution(perSide: [], exact: false, nearestBelow: bar, nearestAbove: nil)
    }

    func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
      var a = abs(lhs)
      var b = abs(rhs)
      while b != 0 {
        (a, b) = (b, a % b)
      }
      return a
    }

    let unitScale = availablePlates
      .map(\.scaled)
      .reduce(0, greatestCommonDivisor)
    let denominations = availablePlates.map { plate in
      (value: plate.value, units: plate.scaled / unitScale)
    }
    let targetPerSide = (target - bar) / 2
    guard let targetPerSideScaled = scaledInteger(targetPerSide),
          abs(targetPerSide - Double(targetPerSideScaled) / scale) <= epsilon
    else {
      return PlateSolution(perSide: [], exact: false, nearestBelow: nil, nearestAbove: nil)
    }

    let lowerCandidate = targetPerSideScaled / unitScale
    let remainder = targetPerSideScaled % unitScale
    let upperCandidate = lowerCandidate + (remainder == 0 ? 0 : 1)
    var reachable = [true]
    var predecessor = [-1]

    func extendReachability(to limit: Int) {
      guard limit >= reachable.count else { return }
      let firstNewAmount = reachable.count
      reachable.append(contentsOf: repeatElement(false, count: limit - reachable.count + 1))
      predecessor.append(contentsOf: repeatElement(-1, count: limit - predecessor.count + 1))
      for amount in firstNewAmount...limit {
        for (index, denomination) in denominations.enumerated()
        where denomination.units <= amount && reachable[amount - denomination.units] {
          reachable[amount] = true
          predecessor[amount] = index
          break
        }
      }
    }

    func breakdown(at units: Int) -> [Double]? {
      guard units >= 0, units < reachable.count, reachable[units] else { return nil }
      var remaining = units
      var result: [Double] = []
      while remaining > 0 {
        let index = predecessor[remaining]
        guard denominations.indices.contains(index) else { return nil }
        let denomination = denominations[index]
        result.append(denomination.value)
        remaining -= denomination.units
      }
      return result.sorted(by: >)
    }

    extendReachability(to: max(lowerCandidate, upperCandidate))
    if remainder == 0, let perSide = breakdown(at: lowerCandidate) {
      return PlateSolution(perSide: perSide, exact: true, nearestBelow: nil, nearestAbove: nil)
    }

    var nearestBelowUnits = lowerCandidate
    while nearestBelowUnits > 0 && !reachable[nearestBelowUnits] {
      nearestBelowUnits -= 1
    }

    var nearestAboveUnits = upperCandidate
    while true {
      extendReachability(to: nearestAboveUnits)
      if reachable[nearestAboveUnits] { break }
      nearestAboveUnits += 1
    }

    let nearestBelow = bar + 2 * Double(nearestBelowUnits * unitScale) / scale
    let nearestAbove = bar + 2 * Double(nearestAboveUnits * unitScale) / scale
    return PlateSolution(
      perSide: [],
      exact: false,
      nearestBelow: nearestBelow,
      nearestAbove: nearestAbove
    )
  }
}
