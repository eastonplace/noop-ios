# Bundle Validation Summary

- Repository pin: `976d7d48df6930046eb38cb2f46febb18a986a48`
- Phase 2 PR: `#27`
- Phase 2 hosted workflow: `30867959471`, passed
- GitHub mutation: none
- Standalone Swift core: builds with Swift 6.2.1 and warnings-as-errors
- Pure core tests: **46 passed**
- Integration Swift files: **24 parsed successfully**
- Repository parity test Swift files: **1 parsed successfully**
- Python release-audit tests: **11 passed**
- SQLite migration/order/replay smoke tests: passed
- Bundle validator: passed
- DST coverage: ordinary, spring-forward, and fall-back local 04:00 rollover passed
- Full private Xcode repository build: not run here because the GitHub connector did not mount the checkout
- Required Codex validation: apply in the real checkout, run XcodeGen, every app/extension/package/iOS test,
  the supplied audit, SQL query plans, large-database performance traces, and the physical overnight matrix
