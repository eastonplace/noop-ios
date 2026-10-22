#!/usr/bin/env python3
"""Load the classifier from the exact protected PR base; bootstrap at high risk.

CI must likewise extract this loader from the protected base where it exists.
The first introducing PR requires independent full-coverage review. Repository
scripts cannot protect an invocation replaced by the PR workflow itself.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--github-output")
    args, extra = parser.parse_known_args()
    if not re.fullmatch(r"[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?", args.base):
        parser.error("base must be an exact commit SHA")
    repo = Path(args.repo).resolve()
    valid = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", f"{args.base}^{{commit}}"], capture_output=True, text=True)
    if valid.returncode or valid.stdout.strip() != args.base.lower():
        parser.error("protected base commit unavailable")
    protected = subprocess.run(["git", "-C", str(repo), "show", f"{args.base}:Tools/ci/classify_pr.py"], capture_output=True)
    forwarded = ["--repo", str(repo), "--base", args.base, "--output", str(Path(args.output).resolve()), *extra]
    if args.github_output:
        forwarded += ["--github-output", str(Path(args.github_output).resolve())]
    # Do not let a caller forge the protected policy provenance.
    if any(arg == "--policy-sha" or arg.startswith("--policy-sha=") for arg in forwarded):
        parser.error("policy revision is set by the loader")
    if protected.returncode == 0:
        source = protected.stdout
    else:
        current = repo / "Tools/ci/classify_pr.py"
        if not current.is_file() or current.is_symlink():
            parser.error("bootstrap classifier unavailable")
        source = current.read_bytes()
        forwarded += ["--bootstrap-high"]
    with tempfile.TemporaryDirectory(prefix="noop-ci-policy-") as directory:
        script = Path(directory) / "classify_pr.py"
        script.write_bytes(source)
        # -I removes the working directory/PYTHONPATH from module search. The
        # classifier is self-contained stdlib; no PR-owned imports are executed.
        return subprocess.run([sys.executable, "-I", str(script), *forwarded, "--policy-sha", args.base], cwd=directory).returncode


if __name__ == "__main__":
    sys.exit(main())
