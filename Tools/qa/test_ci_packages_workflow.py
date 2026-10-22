"""Structural controls for the package execution lane (no native builds)."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class PackageWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (ROOT / '.github/workflows/swift-packages.yml').read_text()

    def test_every_pr_triggers_with_legacy_matrix_name(self):
        self.assertRegex(self.workflow, r'(?m)^  pull_request:\s*$')
        self.assertNotRegex(self.workflow, r'(?m)^    paths(?:-ignore)?:')
        self.assertIn('name: test (${{ matrix.package }})', self.workflow)
        self.assertIn('include: ${{ fromJSON(needs.plan.outputs.host_matrix) }}', self.workflow)

    def test_selected_package_test_is_single_authoritative_command(self):
        self.assertEqual(len(re.findall(r'(?m)^\s+swift test\b', self.workflow)), 1)
        self.assertNotRegex(self.workflow, r'(?m)^\s+swift build\b')
        self.assertIn('runs-on: ${{ matrix.runner }}', self.workflow)
        self.assertIn('name: Record planned package skip', self.workflow)
        self.assertIn('if: matrix.run == false', self.workflow)
        self.assertIn('if: matrix.run == true', self.workflow)

    def test_protected_policy_and_tested_source_used_without_write_token(self):
        self.assertIn('git show "$BASE_SHA:Tools/ci/load_plan.py"', self.workflow)
        self.assertIn('python3 -I "$loader"', self.workflow)
        self.assertIn('--tested-sha "$TESTED_SHA"', self.workflow)
        self.assertIn('name: Tested source ${{ github.sha }}', self.workflow)
        self.assertIn('fetch-depth: 0', self.workflow)
        self.assertNotIn('pull_request_target:', self.workflow)
        self.assertNotRegex(self.workflow, r'(?m)^\s+[a-z-]+: write\s*$')
        self.assertIn('workflow_call:', self.workflow)
        self.assertIn('inputs.full', self.workflow)


if __name__ == '__main__':
    unittest.main()
