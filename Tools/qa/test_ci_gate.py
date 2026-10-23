"""Gate controls: fabricated GitHub API evidence must fail closed."""
import copy
import hashlib
import importlib.util
import itertools
import json
import os
import shutil
import subprocess
import tempfile
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LEGACY = ["NoopPhase34Core", "WhoopProtocol", "OuraProtocol", "WhoopStore", "StrandAnalytics", "StrandImport", "StrandDesign", "NoopLocalAccess"]
APP_ONLY = ["CoachPresentation", "ReceiptLiftActivity", "ReceiptLiftFeature"]
HEAD, TESTED, BASE = "a" * 40, "b" * 40, "c" * 40


def module(name):
    path = ROOT / "Tools" / "ci" / f"{name}.py"
    if not path.exists():
        raise AssertionError(f"Missing gate implementation: {path}")
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    sys.modules[name] = loaded
    spec.loader.exec_module(loaded)
    return loaded


def seal(plan):
    body = {key: value for key, value in plan.items() if key != "plan_hash"}
    plan["plan_hash"] = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return plan


def fixture(docs=False):
    selected = [] if docs else ["WhoopProtocol", "WhoopStore"]
    plan = seal({
        "schema_version": 1, "base_sha": BASE, "head_sha": HEAD,
        "tested_sha": TESTED, "policy_sha": BASE,
        "mode": "docs" if docs else "high", "reasons": ["fixture"],
        "run_app": not docs, "native_level": "none" if docs else "full",
        "native_tests": [] if docs else ["NOOPiOSTests"], "ui_tests": [] if docs else ["NOOPCoachUITests/Example/testExample"],
        "host_packages": selected,
        "host_matrix": [{"package": name, "run": name in selected, "runner": "macos-26" if name in selected else "ubuntu-latest"} for name in LEGACY],
        "package_validation": [{"package": name, "lane": "host_test", "affected": name in selected, "dependencies": []} for name in LEGACY] + [{"package": name, "lane": "app_build", "affected": False, "dependencies": []} for name in APP_ONLY],
    })
    jobs = [{"id": 10, "name": "plan", "run_id": 123, "run_attempt": 2, "status": "completed", "conclusion": "success", "steps": [
        {"name": f"Tested source {TESTED}", "status": "completed", "conclusion": "success"},
    ]}]
    for index, name in enumerate(LEGACY):
        chosen = name in selected
        jobs.append({"id": 20 + index, "name": f"test ({name})", "run_id": 123, "run_attempt": 2, "status": "completed", "conclusion": "success", "steps": [
            {"name": f"Tested source {TESTED}", "status": "completed", "conclusion": "success" if chosen else "skipped"},
            {"name": "Test selected package", "status": "completed", "conclusion": "success" if chosen else "skipped"},
            {"name": "Record planned package skip", "status": "completed", "conclusion": "skipped" if chosen else "success"},
        ]})
    packages = {
        "repository": "eastonplace/noop-ios", "workflow_path": ".github/workflows/swift-packages.yml", "job_prefix": "",
        "run": {"id": 123, "head_sha": HEAD, "event": "pull_request", "path": ".github/workflows/swift-packages.yml", "run_attempt": 2, "status": "completed", "conclusion": "success"},
        "jobs": jobs, "jobs_run_attempt": 2,
        "jobs_endpoint": "/repos/eastonplace/noop-ios/actions/runs/123/attempts/2/jobs",
    }
    app = {"run_id": 456, "run_attempt": 3, "workflow_path": ".github/workflows/app-build.yml", "head_sha": HEAD, "tested_sha": TESTED, "event": "pull_request", "plan_hash": plan["plan_hash"],
           "jobs": {"change-plan": "success", "source-audits": "success", "build-and-test": "success"},
           "steps": {name: "skipped" if docs else "success" for name in ("build", "native", "ui", "safety")}}
    return plan, packages, app


class GateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gate = module("validate_gate")

    def errors(self, plan, packages, app, **kwargs):
        return self.gate.validate_gate(plan, packages, app, head_sha=HEAD, tested_sha=TESTED,
                                       event="pull_request", repository="eastonplace/noop-ios", base_sha=BASE, app_run_id=456, app_run_attempt=3, **kwargs)

    def test_selected_and_explicit_linux_skips_pass(self):
        self.assertEqual(self.errors(*fixture()), [])
        self.assertEqual(self.errors(*fixture(docs=True)), [])

    def test_every_required_app_status_combination(self):
        for statuses in itertools.product(("success", "failure", "cancelled", "skipped", None), repeat=3):
            plan, packages, app = fixture()
            app["jobs"] = dict(zip(("change-plan", "source-audits", "build-and-test"), statuses))
            with self.subTest(statuses=statuses):
                self.assertEqual(bool(self.errors(plan, packages, app)), statuses != ("success", "success", "success"))

    def test_each_app_stage_failure_cancel_skip_or_missing_blocks(self):
        for stage, result in itertools.product(("build", "native", "ui", "safety"), ("failure", "cancelled", "skipped", None)):
            plan, packages, app = fixture()
            app["steps"][stage] = result
            with self.subTest(stage=stage, result=result):
                self.assertTrue(self.errors(plan, packages, app))

    def test_docs_cannot_claim_unplanned_native_success(self):
        plan, packages, app = fixture(docs=True)
        app["steps"]["native"] = "success"
        self.assertTrue(self.errors(plan, packages, app))

    def test_stale_head_tested_sha_plan_hash_or_manual_dispatch_blocks(self):
        mutations = (
            lambda p, q, a: p.update(head_sha="d" * 40),
            lambda p, q, a: a.update(tested_sha="d" * 40),
            lambda p, q, a: a.update(plan_hash="d" * 64),
            lambda p, q, a: q["run"].update(head_sha="d" * 40),
            lambda p, q, a: q["run"].update(event="workflow_dispatch"),
            lambda p, q, a: q["run"].update(path=".github/workflows/unrelated.yml"),
            lambda p, q, a: q.update(repository="someone/else"),
        )
        for mutate in mutations:
            args = fixture()
            mutate(*args)
            self.assertTrue(self.errors(*args))

    def test_failed_cancelled_missing_and_skipped_matrix_jobs_block(self):
        for outcome in ("failure", "cancelled", "skipped", "timed_out", None):
            args = fixture()
            args[1]["jobs"][2]["conclusion"] = outcome
            self.assertTrue(self.errors(*args))
        args = fixture()
        args[1]["jobs"].pop()
        self.assertTrue(self.errors(*args))

    def test_false_planned_skip_and_missing_test_step_block(self):
        args = fixture()
        chosen = next(job for job in args[1]["jobs"] if job["name"] == "test (WhoopProtocol)")
        chosen["steps"][1]["conclusion"] = "skipped"
        chosen["steps"][2]["conclusion"] = "success"
        self.assertTrue(self.errors(*args))
        args = fixture()
        args[1]["jobs"][2]["steps"].pop(1)
        self.assertTrue(self.errors(*args))

    def test_wrong_attempt_duplicate_job_and_missing_source_marker_block(self):
        for mutate in (
            lambda q: q["jobs"][1].update(run_attempt=1),
            lambda q: q["jobs"].append(copy.deepcopy(q["jobs"][1])),
            lambda q: q["jobs"][2]["steps"].pop(0),
            lambda q: q["jobs"][2]["steps"][0].update(name=f"Tested source {'d' * 40}"),
        ):
            args = fixture()
            mutate(args[1])
            self.assertTrue(self.errors(*args))

    def test_plan_tampering_unknown_package_and_legacy_omission_block(self):
        for mutate in (
            lambda p: p.update(host_packages=[]),
            lambda p: p["host_matrix"].pop(),
            lambda p: p["package_validation"].append({"package": "NewUnknown", "lane": "app_build"}),
            lambda p: p["host_matrix"][0].update(runner="macos-26"),
        ):
            args = fixture()
            mutate(args[0])
            seal(args[0])
            args[2]["plan_hash"] = args[0]["plan_hash"]
            self.assertTrue(self.errors(*args))

    def test_full_mode_cannot_skip_any_host_package(self):
        args = fixture()
        args[0]["mode"] = "full"
        seal(args[0])
        args[2]["plan_hash"] = args[0]["plan_hash"]
        self.assertTrue(self.errors(*args))

    def test_full_ui_inventory_and_high_native_cannot_be_incomplete(self):
        for field, value in (("native_tests", []), ("native_tests", ["NOOPiOSTests/OnlyOne"])):
            args = fixture()
            args[0][field] = value
            seal(args[0])
            args[2]["plan_hash"] = args[0]["plan_hash"]
            self.assertTrue(self.errors(*args))
        args = fixture(docs=True)
        args[0]["ui_tests"] = ["NOOPCoachUITests/Example/testUnexpected"]
        seal(args[0])
        args[2]["plan_hash"] = args[0]["plan_hash"]
        self.assertTrue(self.errors(*args))

    def test_affected_host_cannot_be_marked_as_planned_skip(self):
        args = fixture()
        args[0]["package_validation"][0]["affected"] = True
        seal(args[0])
        args[2]["plan_hash"] = args[0]["plan_hash"]
        self.assertTrue(self.errors(*args))

    def test_missing_or_stale_attempt_query_evidence_blocks(self):
        for mutate in (
            lambda q: q.pop("jobs_run_attempt"),
            lambda q: q.update(jobs_run_attempt=1),
            lambda q: q.update(jobs_endpoint="/repos/eastonplace/noop-ios/actions/runs/123/attempts/1/jobs"),
        ):
            args = fixture()
            mutate(args[1])
            self.assertTrue(self.errors(*args))

    def test_stale_base_or_foreign_app_run_attempt_workflow_blocks(self):
        for mutate in (
            lambda p, a: (p.update(base_sha="d" * 40, policy_sha="d" * 40), seal(p), a.update(plan_hash=p["plan_hash"])),
            lambda p, a: a.update(run_id=455),
            lambda p, a: a.update(run_attempt=2),
            lambda p, a: a.update(workflow_path=".github/workflows/unrelated.yml"),
        ):
            args = fixture()
            mutate(args[0], args[2])
            self.assertTrue(self.errors(*args))

    def test_complete_full_inventory_passes_and_missing_ui_case_blocks(self):
        plan, packages, app = fixture()
        plan["mode"] = "full"
        plan["host_packages"] = list(LEGACY)
        plan["ui_inventory"] = list(plan["ui_tests"])
        for entry in plan["host_matrix"]:
            entry.update(run=True, runner="macos-26")
        for job in packages["jobs"][1:]:
            for step in job["steps"]:
                step["conclusion"] = "skipped" if step["name"] == "Record planned package skip" else "success"
        seal(plan)
        app["plan_hash"] = plan["plan_hash"]
        self.assertEqual(self.errors(plan, packages, app), [])
        plan["ui_inventory"].append("NOOPCoachUITests/Example/testAnother")
        seal(plan)
        app["plan_hash"] = plan["plan_hash"]
        self.assertTrue(self.errors(plan, packages, app))

    def test_every_matrix_context_failure_cancellation_and_skip_blocks(self):
        for index, result in itertools.product(range(1, 9), ("failure", "cancelled", "skipped", None)):
            args = fixture()
            args[1]["jobs"][index]["conclusion"] = result
            with self.subTest(index=index, result=result):
                self.assertTrue(self.errors(*args))

    def test_official_api_workflow_ref_suffix_is_allowed(self):
        args = fixture()
        args[1]["run"]["path"] += "@refs/pull/76/merge"
        self.assertEqual(self.errors(*args), [])

    def test_malformed_json_shape_fails_instead_of_raising(self):
        for value in (None, {}, [], [None], [["unsafe"]]):
            args = fixture()
            args[0]["host_packages"] = value
            seal(args[0])
            self.assertTrue(self.errors(*args))

    def test_reusable_full_wrapper_requires_explicit_workflow_and_prefix(self):
        plan, packages, app = fixture()
        packages["workflow_path"] = packages["run"]["path"] = ".github/workflows/noop-full-validation.yml"
        packages["job_prefix"] = "packages / "
        packages["run"]["status"] = "in_progress"
        packages["run"]["conclusion"] = None
        for job in packages["jobs"]:
            job["name"] = "packages / " + job["name"]
        self.assertTrue(self.errors(plan, packages, app))
        self.assertEqual(self.errors(plan, packages, app, workflow_path=".github/workflows/noop-full-validation.yml", job_prefix="packages / ", allow_in_progress=True), [])


class WaiterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.waiter = module("wait_for_packages")

    def test_latest_current_head_run_attempt_selected(self):
        runs = [
            {"id": 1, "head_sha": "d" * 40, "event": "pull_request", "path": ".github/workflows/swift-packages.yml", "run_attempt": 1},
            {"id": 2, "head_sha": HEAD, "event": "workflow_dispatch", "path": ".github/workflows/swift-packages.yml", "run_attempt": 1},
            {"id": 3, "head_sha": HEAD, "event": "pull_request", "path": ".github/workflows/swift-packages.yml", "run_attempt": 2},
        ]
        selected = self.waiter.select_run(runs, head_sha=HEAD, event="pull_request", workflow_path=".github/workflows/swift-packages.yml")
        self.assertEqual(selected["id"], 3)

    def test_timeout_never_returns_success(self):
        tick = iter((0, 0, 1, 2, 3, 4))
        with self.assertRaisesRegex(self.waiter.PackageWaitError, "Timed out"):
            self.waiter.wait_for_packages(repository="eastonplace/noop-ios", head_sha=HEAD, tested_sha=TESTED,
                event="pull_request", plan=fixture()[0], fetch=lambda path: {"workflow_runs": []},
                sleep=lambda seconds: None, monotonic=lambda: next(tick), timeout_seconds=2)

    def test_completed_missing_matrix_fails_without_polling_to_success(self):
        plan, evidence, _ = fixture()
        run = evidence["run"]
        def fetch(path):
            if "/attempts/" in path:
                return {"jobs": evidence["jobs"][:-1], "total_count": 8}
            return {"workflow_runs": [run]}
        with self.assertRaisesRegex(self.waiter.PackageWaitError, "missing"):
            self.waiter.wait_for_packages(repository="eastonplace/noop-ios", head_sha=HEAD, tested_sha=TESTED,
                event="pull_request", plan=plan, fetch=fetch, sleep=lambda _: None)

    def test_api_evidence_success_uses_exact_attempt_endpoint(self):
        plan, evidence, _ = fixture()
        # Real GitHub job responses need not repeat run_attempt on each job.
        for job in evidence["jobs"]:
            job.pop("run_attempt")
        queried = []
        def fetch(path):
            queried.append(path)
            if "/attempts/" in path:
                return {"jobs": evidence["jobs"], "total_count": len(evidence["jobs"])}
            return {"workflow_runs": [evidence["run"]]}
        actual = self.waiter.wait_for_packages(repository="eastonplace/noop-ios", head_sha=HEAD, tested_sha=TESTED,
                event="pull_request", plan=plan, fetch=fetch, sleep=lambda _: None)
        self.assertEqual(actual["jobs_run_attempt"], 2)
        self.assertIn("/runs/123/attempts/2/jobs", queried[-1])

    def test_newest_matching_run_is_never_replaced_by_older_green(self):
        plan, evidence, _ = fixture()
        old = dict(evidence["run"], id=122)
        current = dict(evidence["run"], conclusion="failure")
        def fetch(path):
            if "/attempts/" in path:
                return {"jobs": evidence["jobs"], "total_count": len(evidence["jobs"])}
            return {"workflow_runs": [old, current]}
        with self.assertRaisesRegex(self.waiter.PackageWaitError, "failure"):
            self.waiter.wait_for_packages(repository="eastonplace/noop-ios", head_sha=HEAD, tested_sha=TESTED,
                event="pull_request", plan=plan, fetch=fetch, sleep=lambda _: None)

    def test_queued_jobs_are_polled_until_current_attempt_completes(self):
        plan, evidence, _ = fixture()
        polls, sleeps = [], []
        def fetch(path):
            if "/attempts/" in path:
                return {"jobs": evidence["jobs"], "total_count": len(evidence["jobs"])}
            polls.append(path)
            return {"workflow_runs": [dict(evidence["run"], status="in_progress", conclusion=None) if len(polls) == 1 else evidence["run"]]}
        self.waiter.wait_for_packages(repository="eastonplace/noop-ios", head_sha=HEAD, tested_sha=TESTED,
                event="pull_request", plan=plan, fetch=fetch, sleep=sleeps.append)
        self.assertEqual(sleeps, [5.0])
        self.assertEqual(len(polls), 2)

    def test_cross_workflow_full_call_accepts_only_its_explicit_run(self):
        plan, evidence, _ = fixture()
        run = dict(evidence["run"], path=".github/workflows/noop-full-validation.yml", status="in_progress", conclusion=None)
        for job in evidence["jobs"]:
            job["name"] = "packages / " + job["name"]
        def fetch(path):
            if "/attempts/" in path:
                return {"jobs": evidence["jobs"], "total_count": len(evidence["jobs"])}
            return run
        actual = self.waiter.wait_for_packages(repository="eastonplace/noop-ios", head_sha=HEAD, tested_sha=TESTED,
            event="pull_request", plan=plan, fetch=fetch, sleep=lambda _: None, run_id=123,
            workflow_path=".github/workflows/noop-full-validation.yml", job_prefix="packages / ")
        self.assertEqual(actual["run"]["id"], 123)

    def test_api_failure_never_becomes_planned_skip(self):
        def fetch(path):
            raise self.waiter.PackageWaitError("HTTP 403")
        with self.assertRaisesRegex(self.waiter.PackageWaitError, "403"):
            self.waiter.wait_for_packages(repository="eastonplace/noop-ios", head_sha=HEAD, tested_sha=TESTED,
                event="pull_request", plan=fixture()[0], fetch=fetch, sleep=lambda _: None)


class IsolatedCLITests(unittest.TestCase):
    def test_protected_temp_pair_ignores_pr_owned_module_search_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            policy, untrusted = Path(directory) / "policy", Path(directory) / "untrusted"
            policy.mkdir()
            untrusted.mkdir()
            for name in ("wait_for_packages.py", "validate_gate.py"):
                shutil.copyfile(ROOT / "Tools/ci" / name, policy / name)
            (untrusted / "validate_gate.py").write_text("raise RuntimeError('PR module was imported')")
            result = subprocess.run([sys.executable, "-I", str(policy / "wait_for_packages.py"), "--help"],
                cwd=untrusted, env=dict(os.environ, PYTHONPATH=str(untrusted)), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--base-sha", result.stdout)

    def test_public_gate_cli_positive_and_negative_control(self):
        with tempfile.TemporaryDirectory() as directory:
            plan, packages, app = fixture()
            paths = [Path(directory) / name for name in ("plan.json", "packages.json", "app.json")]
            for path, value in zip(paths, (plan, packages, app)):
                path.write_text(json.dumps(value))
            command = [sys.executable, "-I", str(ROOT / "Tools/ci/validate_gate.py"),
                "--plan", str(paths[0]), "--packages", str(paths[1]), "--app-results", str(paths[2]),
                "--head-sha", HEAD, "--base-sha", BASE, "--tested-sha", TESTED,
                "--event", "pull_request", "--repository", "eastonplace/noop-ios",
                "--app-run-id", "456", "--app-run-attempt", "3"]
            positive = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(positive.returncode, 0, positive.stderr)
            app["steps"]["native"] = "failure"
            paths[2].write_text(json.dumps(app))
            negative = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(negative.returncode, 1)
            self.assertIn("app stage native", negative.stderr)


if __name__ == "__main__":
    unittest.main()
