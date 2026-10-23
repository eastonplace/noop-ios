import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("ci_timings", Path(__file__).parents[1] / "ci/report_timings.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def job(name, start, end, result="success"):
    return {"name": name, "created_at": "2026-10-22T00:00:00Z", "started_at": f"2026-10-22T00:{start}:00Z",
            "completed_at": f"2026-10-22T00:{end}:00Z" if end else None,
            "status": "completed" if end else "in_progress", "conclusion": result, "steps": []}


class TimingTests(unittest.TestCase):
    def test_parallel_jobs_use_wall_span_not_sum(self):
        result = module.report([{"run": 1, "jobs": [job("source-audits", "01", "02"), job("build-and-test", "01", "10"), job("test (A)", "03", "08")]}])
        self.assertEqual(result["median_wall_seconds"], 600)
        self.assertEqual(result["runs"][0]["observed_execution_span_seconds"], 540)
        self.assertEqual(result["median_first_feedback_seconds"], 120)
        self.assertIsNone(result["cache_hit_rate"])

    def test_failed_or_pending_runs_never_count_as_successful_timing(self):
        for end, result in [("10", "failure"), ("10", "cancelled"), (None, None)]:
            with self.subTest(result=result):
                report = module.report([{"run": 1, "jobs": [job("build-and-test", "01", end, result)]}])
                self.assertEqual(report["successful_run_count"], 0)
                self.assertIsNone(report["median_wall_seconds"])

    def test_missing_timestamps_do_not_become_zero(self):
        data = job("build-and-test", "01", "10")
        del data["created_at"]
        result = module.report([{"run": 1, "jobs": [data]}])
        self.assertIsNone(result["median_wall_seconds"])
        self.assertIsNone(result["runs"][0]["queue_to_first_start_seconds"])

    def test_partial_inventory_and_reversed_times_are_rejected(self):
        with self.assertRaises(ValueError):
            module.report([{"run": 1, "jobs": {"total_count": 2, "jobs": [job("build-and-test", "01", "10")]}}])
        with self.assertRaises(ValueError):
            module.duration("2026-10-22T00:02:00Z", "2026-10-22T00:01:00Z")


if __name__ == "__main__":
    unittest.main()
