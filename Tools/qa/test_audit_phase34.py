import importlib.util
import tempfile
import unittest
import sys
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("audit_phase34.py")
spec = importlib.util.spec_from_file_location("audit_phase34", MODULE_PATH)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class AuditTests(unittest.TestCase):
    def scan_text(self, relative_path: str, text: str):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / relative_path
            path.parent.mkdir(parents=True)
            path.write_text(text)
            return module.scan(root)

    def test_flags_trends_bypass(self):
        findings = self.scan_text(
            "Strand/Screens/TrendsView.swift",
            'repo.exploreSeries(key: "sleep_performance", source: "my-whoop")',
        )
        self.assertIn("P34-004", {item.code for item in findings})

    def test_flags_publish_before_save(self):
        findings = self.scan_text(
            "Strand/Data/Repository.swift",
            "publishTodayHealthSnapshot(resolved, persist: false)\n"
            "let accepted = try await store.saveTodayHealthSnapshot(resolved)",
        )
        self.assertIn("P34-015", {item.code for item in findings})

    def test_flags_json_blob_work_identity(self):
        findings = self.scan_text(
            "Packages/WhoopStore/Sources/WhoopStore/HistoricalAnalysisWorkStore.swift",
            "SELECT * FROM historicalAnalysisWork WHERE workKindJSON = ?",
        )
        self.assertIn("P34-019", {item.code for item in findings})

    def test_flags_fixed_repository_day_arithmetic(self):
        findings = self.scan_text(
            "Strand/Data/Repository.swift",
            "let lo = nowTs - nDays * 86_400",
        )
        self.assertIn("P34-025", {item.code for item in findings})

    def test_flags_unordered_source_authority(self):
        findings = self.scan_text(
            "Strand/Data/Repository.swift",
            "let ids = Array(Set(importedReadIds + computedReadIds))",
        )
        self.assertIn("P34-027", {item.code for item in findings})

    def test_flags_healthkit_snapshot_only_identity(self):
        findings = self.scan_text(
            "Packages/WhoopStore/Sources/WhoopStore/ExternalPublicationOutboxStore.swift",
            'table.uniqueKey(["contextId", "snapshotGeneration", "destination"])',
        )
        self.assertIn("P34-028", {item.code for item in findings})

    def test_flags_single_work_merge_candidate(self):
        findings = self.scan_text(
            "Packages/WhoopStore/Sources/WhoopStore/HistoricalAnalysisWorkStore.swift",
            "SELECT workKindKey FROM historicalAnalysisWork "
            "WHERE state IN ('pending','retryable') LIMIT 1",
        )
        self.assertIn("P34-031", {item.code for item in findings})

    def test_flags_oldest_latest_state_drain(self):
        findings = self.scan_text(
            "Packages/WhoopStore/Sources/WhoopStore/ExternalPublicationOutboxStore.swift",
            "SELECT * FROM externalPublicationOutbox ORDER BY snapshotGeneration ASC",
        )
        self.assertIn("P34-029", {item.code for item in findings})

    def test_flags_healthkit_without_exact_mutation_identity(self):
        findings = self.scan_text(
            "StrandiOS/App/StrandiOSApp.swift",
            "await publishHealthKitWriteOnly(projection)",
        )
        self.assertIn("P34-030", {item.code for item in findings})

    def test_flags_outbox_without_superseded_state(self):
        findings = self.scan_text(
            "Packages/WhoopStore/Sources/WhoopStore/Database.swift",
            "CHECK (state IN ('pending','leased','retryable','succeeded','quarantined'))",
        )
        self.assertIn("P34-032", {item.code for item in findings})

    def test_clean_tree_is_clean(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(module.scan(Path(tmp)), [])


if __name__ == "__main__":
    unittest.main()
