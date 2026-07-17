# NOOP Strain V2

## Objective

Replace the Edwards/24-hour-ceiling scorer with a transparent, WHOOP-informed model that credits background movement, uses timestamp-aware cardiovascular load, and reaches the top of the 0–21 display scale under genuinely extreme exertion.

## Requirements

- Provide `StrainScorerV2` modes for physiological days and activities.
- Integrate adjacent HR timestamps; intervals over 90 seconds are missing coverage.
- Use continuous HRR load anchors: 30%=0, 40%=0.05, 60%=0.20, 70%=0.45, 80%=0.70, 90%+=1.0 equivalent minutes per minute.
- Map effective load with `21 × (1 − exp(−load / 32))`, then store through the existing 0–100 boundary.
- Physiological days include a capped worn-sleep seed plus non-additive step and active-energy floors.
- Activities use cardiovascular load only.
- Preserve imported WHOOP strain exactly.
- Shadow V2 before canonical cutover and retain version provenance.
- Muscular load is out of scope.

## Acceptance anchors

- Eight worn sleep hours produce approximately 4.0.
- 6,000–12,000-step quiet days remain between 4 and 7.
- 60 minutes at 70–79% HRR produces 13–14.5 Day Strain.
- 60 minutes at 90%+ HRR with a 4.0 seed produces 18–19.
- Six hours at 90%+ HRR produces at least 20.9.
- Dense and 30-second sparse equivalents differ by at most 0.2.

