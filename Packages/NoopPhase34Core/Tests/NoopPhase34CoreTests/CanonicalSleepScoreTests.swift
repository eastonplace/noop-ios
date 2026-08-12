import Testing
@testable import NoopPhase34Core

private func candidate(_ model: SleepScoreModel, _ value: Double, generation: Int64 = 1) throws -> SleepScoreCandidate {
    try SleepScoreCandidate(
        day: CivilDay(key: "2026-08-03"),
        value: value,
        sourceId: model.rawValue,
        model: model,
        generation: generation
    )
}

@Test func importedWinsEveryMode() throws {
    for mode in SleepScoreMode.allCases {
        let result = try CanonicalSleepScoreResolver.resolve(
            day: CivilDay(key: "2026-08-03"),
            mode: mode,
            imported: [candidate(.importedWhoop, 91)],
            v2: [candidate(.noopV2, 83)],
            legacy: [candidate(.noopLegacy, 79)]
        )
        #expect(result.production?.value == 91)
    }
}

@Test func shadowKeepsLegacyAuthorityAndV2Diagnostic() throws {
    let result = try CanonicalSleepScoreResolver.resolve(
        day: CivilDay(key: "2026-08-03"),
        mode: .shadow,
        v2: [candidate(.noopV2, 83)],
        legacy: [candidate(.noopLegacy, 79)]
    )
    #expect(result.production?.model == .noopLegacy)
    #expect(result.production?.value == 79)
    #expect(result.shadow?.model == .noopV2)
}

@Test func shadowUsesV2RatherThanBlankWhenLegacyMissing() throws {
    let result = try CanonicalSleepScoreResolver.resolve(
        day: CivilDay(key: "2026-08-03"),
        mode: .shadow,
        v2: [candidate(.noopV2, 83)]
    )
    #expect(result.production?.model == .noopV2)
}

@Test func onUsesV2AheadOfLegacy() throws {
    let result = try CanonicalSleepScoreResolver.resolve(
        day: CivilDay(key: "2026-08-03"),
        mode: .on,
        v2: [candidate(.noopV2, 83)],
        legacy: [candidate(.noopLegacy, 79)]
    )
    #expect(result.production?.value == 83)
}

@Test func shadowUsesPersistedV2BeforeProvisionalWhenLegacyMissing() throws {
    let result = try CanonicalSleepScoreResolver.resolve(
        day: CivilDay(key: "2026-08-03"),
        mode: .shadow,
        v2: [candidate(.noopV2, 83)],
        provisional: [candidate(.provisionalComposite, 71)]
    )
    #expect(result.production?.model == .noopV2)
    #expect(result.production?.value == 83)
}

@Test func explicitSourceAuthorityBeatsLexicographicSourceOrder() throws {
    let day = try CivilDay(key: "2026-08-03")
    let active = try SleepScoreCandidate(
        day: day,
        value: 84,
        sourceId: "active-source",
        model: .importedWhoop,
        generation: 7,
        authorityRank: 100
    )
    let canonical = try SleepScoreCandidate(
        day: day,
        value: 91,
        sourceId: "zz-canonical-source",
        model: .importedWhoop,
        generation: 7,
        authorityRank: 10
    )
    let result = try CanonicalSleepScoreResolver.resolve(
        day: day,
        mode: .on,
        imported: [canonical, active]
    )
    #expect(result.production?.sourceId == "active-source")
    #expect(result.production?.value == 84)
}
