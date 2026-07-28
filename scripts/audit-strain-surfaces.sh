#!/bin/bash
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

violations=""
while IFS= read -r match; do
    case "$match" in
        Strand/Screens/TrendsView.swift:*|\
        Strand/Screens/TrendsReportView.swift:*|\
        Strand/Screens/WeeklyDigestView.swift:*|\
        Strand/Screens/IntelligenceView.swift:*|\
        Strand/Screens/ManualWorkoutSheet.swift:*|\
        Strand/Screens/InsightsHubView.swift:*|\
        Strand/Screens/ScoringGuideView.swift:*|\
        Strand/Screens/TodayView.swift:*|\
        Strand/Screens/CoupledView.swift:*|\
        Strand/Screens/TrendsSnapshotModels.swift:*|\
        Strand/Screens/TrendsView+SelectedRange.swift:*|\
        StrandiOS/App/SmartAlarmRuntimeController.swift:*|\
        StrandiOS/Widgets/LiveUpdatePolicies.swift:*|\
        StrandiOS/Widgets/LiveActivityController.swift:*)
            ;;
        *)
            violations="${violations}${match}\n"
            ;;
    esac
done <<EOF
$(rg -n '\.strain\b' Strand/Screens StrandiOS StrandWidgets StrandWatch 2>/dev/null || true)
EOF

if [ -n "$violations" ]; then
    printf 'Direct Strain presentation reads require resolver review:\n%b' "$violations"
    exit 1
fi

printf 'Strain surface audit passed: remaining direct reads are classified helpers, V2 engine results, edit-preservation checks, or enum cases.\n'
