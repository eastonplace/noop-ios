# WHOOP 4 background sync and battery refresh

Goal: identify and repair concrete causes of delayed WHOOP 4 overnight history catch-up and stale automatic battery readings. Compare the retained iOS paths with WHOOP 5/MG and current RyanBR upstream. Ship a separate 2.0.4 PR stacked after the existing 2.0.3 Sleep PR82, as Easton selected on October 25.

Evidence: a WHOOP 4 supplied incomplete overnight history that advanced during a foreground inspection. This proves foreground catch-up, not a particular root cause or guaranteed background delivery. No raw phone database is retained. The earlier deployment and calibration check are complete and outside this PR. Device-specific findings remain in private workspace evidence.

1. Trace background wake, restoration and history scheduling separately from battery refresh.
2. Pin and compare upstream implementation. Distinguish protocol evidence from assumptions and platform limits.
3. Add focused failing regressions for confirmed causes, then make bounded fixes. Preserve receipt ownership, cancellation, source identity, power limits and all stored phone data.
4. Review the combined diff. Run affected native/package tests, source and release audits, and the protected CI classifier. Keep normal required CI; do not repeat unrelated passing suites after small patches.
5. Open and attach a PR targeting the PR82 branch, version 2.0.4 build 256, with evidence and remaining physical-device limits. No merge, phone installation, live strap commands, reset, re-pair, database export or publication is part of this follow-up.

Status: root fixes and independent review complete; initial 141 native cases and final 88 affected cases passed. Source and release audits passed. PR preparation and hosted CI remain. Root owns integration and release metadata; at most four active agents were used. Detailed evidence is in docs/reviews/2026-10-25-whoop4-background-battery.md.

Confirmed source gaps: caught-up WHOOP 4 cancels its OS background request; a productive capped pass can clear debt against a stale connection-time range; proprietary battery events are decoded but their percentage is omitted from the live state. Existing background reconnect handoff and locked-store protection already exist. The empty automatic battery request body is supported by upstream and is not a confirmed cause.

Upstream comparison pinned ryanbr/noop at 6d750391bda65b99d0d74ef8a0acce2d7188636e. Its battery event update is a reference implementation, with physical validation still required. The local adaptation must reject incomplete or corrupt frames, unsupported families, stale owners, out-of-range SoC, stale/future timestamps and regressions behind a newer command reading. Clock fallback must not make replay appear current.
