import SwiftUI

enum LiftMedia {
  static let resourceBundle = Bundle.module
  private static let safeAliasAssetsByName: [String: String] = [
    "ab machine or cable crunch": "catalog_0175_WW95auq",
    "back extension": "catalog_0573_rUXfn3R",
    "bulgarian split squat": "catalog_0410_qx4fgX7",
    "cable fly or pec deck": "catalog_0227_Pr9Rhf4",
    "calf raise": "catalog_1373_bJYHBIN",
    "chest supported row": "catalog_0327_7vG5o25",
    "hack squat": "catalog_0743_Qa55kX1",
    "hanging knee raise": "catalog_0011_03lzqwk",
    "hammer curl": "catalog_1678_IGtBdNT",
    "hip thrust": "catalog_3236_Pjbc0Kt",
    "incline dumbbell curl": "catalog_0318_ae9UoXQ",
    "incline dumbbell press": "catalog_0314_ns0SIbU",
    "lat pulldown": "catalog_2330_LEprlgG",
    "leg extension": "catalog_0585_my33uHU",
    "leg press": "catalog_0739_10Z2DXU",
    "lying leg curl": "catalog_0586_17lJ1kr",
    "machine chest press": "catalog_0577_T0yTjgW",
    "machine row or cable row": "catalog_0861_fUBheHs",
    "machine shoulder press": "catalog_0603_67n3r98",
    "overhead cable extension": "catalog_0194_2IxROQ1",
    "pallof press or plank": "catalog_0979_9pa4H5m",
    "rear delt fly": "catalog_0602_myfUsKf",
    "romanian deadlift": "catalog_0085_wQ2c4XD",
    "rope pushdown": "catalog_0200_dU605di",
    "russian twist or hanging knee raise": "catalog_0687_XVDdcoj",
    "seated leg curl": "catalog_0599_Zg3XY7P",
    "smith incline press": "catalog_0757_5v7KYld",
    "straight arm pulldown": "catalog_0237_DT14T9T",
    "straight bar pushdown": "catalog_0201_3ZflifB",
    "t bar row": "catalog_0606_aaXr7ld"
  ]

  static func imageName(for exercise: LiftExercise) -> String? {
    imageName(forName: exercise.name)
  }

  static func imageName(forName name: String) -> String? {
    let key = LiftExerciseCatalog.normalizedName(name)
    if let aliasAsset = safeAliasAssetsByName[key] {
      return aliasAsset
    }
    return LiftExerciseCatalog.imageAssetsByNormalizedName[key]
  }

  static func receiptNumber(for session: LiftSession, in sessions: [LiftSession]) -> String {
    let targetID = session.id.uuidString
    let precedingCount = sessions.reduce(into: 0) { count, candidate in
      guard candidate.endedAt != nil, candidate.id != session.id else { return }
      if candidate.startedAt < session.startedAt
        || (candidate.startedAt == session.startedAt && candidate.id.uuidString < targetID) {
        count += 1
      }
    }
    return String(format: "#%05d", precedingCount + 1)
  }
}
