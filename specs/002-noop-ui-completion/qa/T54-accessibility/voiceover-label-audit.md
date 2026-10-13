# T54 VoiceOver label audit

Runtime accessibility-tree snapshots were captured on the seeded iPhone Pro Max
simulator with XcodeBuildMCP after each screen settled.

- Today: 155 elements. The score controls expose `32, Recovery, Low` with
  `32 percent`, `12.7, Strain, Moderate`, and `93, Sleep, Good` with `93 percent`.
  The day picker, Today-at-a-glance row, stress card, Health Monitor, Updates,
  Devices, Edit Key Metrics, and Quick Actions all expose descriptive labels.
- Sleep: 60 elements. The sleep-mark controls expose `Log going to sleep` and
  `Log waking up`; the tree also exposes the score, duration, efficiency, resting
  heart rate, stage legend, stage times, asleep/woke times, and in-bed duration.

No unlabeled actionable control appeared in either runtime target list.
