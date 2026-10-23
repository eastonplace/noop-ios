import XCTest
@testable import StrandAnalytics

final class SleepInterpolationRegressionTests: XCTestCase {
    func testSparseHRMatchesPreviousAlgorithmBitForBit() {
        for count in [0, 1, 10, 240, 960, 2_880] {
            for spacing in [1, 2, 7, 31] {
                let input: [Double] = (0..<count).map { i in
                    i % spacing == 0 && i > 3 && i < count - 3
                        ? 50.0 + Double((i * 13) % 31) / 7.0 : Double.nan
                }
                XCTAssertEqual(SleepStager.dogHRVariability(input).map(\.bitPattern),
                               reference(input).map(\.bitPattern), "count=\(count) spacing=\(spacing)")
            }
        }
    }

    func testSparseHRBenchmarkWhenRequested() {
        guard ProcessInfo.processInfo.environment["NOOP_ANALYTICS_BENCHMARK"] == "1" else { return }
        let input: [Double] = (0..<2_880).map { i -> Double in
            guard i % 2 == 0 else { return .nan }
            return 50.0 + Double(i % 31) / 7.0
        }
        var oldTimes: [Double] = []
        var newTimes: [Double] = []
        for _ in 0..<5 {
            var start = Date()
            let expected = reference(input)
            oldTimes.append(Date().timeIntervalSince(start))
            start = Date()
            let actual = SleepStager.dogHRVariability(input)
            newTimes.append(Date().timeIntervalSince(start))
            XCTAssertEqual(actual.map(\.bitPattern), expected.map(\.bitPattern))
        }
        let oldMedian = oldTimes.sorted()[2]
        let newMedian = newTimes.sorted()[2]
        print("Sparse HR 24h/30s, 50% missing, median of 5: old=\(oldMedian)s new=\(newMedian)s speedup=\(oldMedian / newMedian)x")
    }

    /// Independent copy of the original full-scan neighbor search, including its arithmetic order.
    private func reference(_ values: [Double]) -> [Double] {
        let n = values.count
        guard n > 0 else { return [] }
        let known = (0..<n).filter { !values[$0].isNaN }
        guard !known.isEmpty else { return Array(repeating: 0, count: n) }
        var filled = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            if !values[i].isNaN { filled[i] = values[i]; continue }
            if i <= known.first! { filled[i] = values[known.first!]; continue }
            if i >= known.last! { filled[i] = values[known.last!]; continue }
            var lo = known.first!, hi = known.last!
            for index in known {
                if index <= i { lo = index }
                if index >= i { hi = index; break }
            }
            if lo == hi { filled[i] = values[lo] }
            else {
                let fraction = Double(i - lo) / Double(hi - lo)
                filled[i] = values[lo] + fraction * (values[hi] - values[lo])
            }
        }
        let fast = SleepStager.convolveReflect(filled, SleepStager.gaussianKernel(sigmaS: SleepStager.hrDogSigma1S))
        let slow = SleepStager.convolveReflect(filled, SleepStager.gaussianKernel(sigmaS: SleepStager.hrDogSigma2S))
        return (0..<n).map { fast[$0] - slow[$0] }
    }
}
