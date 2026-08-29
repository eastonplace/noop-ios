#!/usr/bin/env python3
from __future__ import annotations
import argparse, base64, json, os, subprocess, sys, tempfile, zlib
from pathlib import Path
PAYLOAD = (
'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'
)
DATA = json.loads(zlib.decompress(base64.b64decode(PAYLOAD)).decode())
PATCH = DATA["patch"]
SOURCE = DATA["source"]
ADDS = DATA["adds_content"]
WORKFLOW_BRANCH_BLOB = DATA["workflow_branch_blob"]
WORKFLOW_PATH = ".github/workflows/app-build.yml"

def cmd(repo: Path, *args: str, check: bool=True) -> str:
    p=subprocess.run(args,cwd=repo,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if check and p.returncode:
        raise RuntimeError(f"command failed ({p.returncode}): {' '.join(args)}\nstdout:\n{p.stdout}\nstderr:\n{p.stderr}")
    return p.stdout.strip()

def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix=f".{path.name}.",suffix=".tmp",dir=path.parent)
    try:
        with os.fdopen(fd,"w",encoding="utf-8") as h: h.write(text)
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def replace_once(text: str, old: str, new: str, path: str, note: str) -> str:
    n=text.count(old)
    if n != 1: raise RuntimeError(f"{path}: expected one exact block, found {n}. Operation: {note}")
    return text.replace(old,new,1)

def replace_between(text: str, start: str, end: str, new: str, path: str, note: str) -> str:
    sc=text.count(start); ec=text.count(end)
    if sc != 1 or ec != 1: raise RuntimeError(f"{path}: marker mismatch start={sc}, end={ec}. Operation: {note}")
    a=text.index(start); b=text.index(end,a+len(start))
    return text[:a]+new+text[b+len(end):]

def verify(repo: Path) -> None:
    if cmd(repo,"git","rev-parse","--is-inside-work-tree",check=False)!="true": raise RuntimeError("not a Git worktree")
    mism=[]
    for rel,expected in SOURCE["blobs"].items():
        p=repo/rel
        if not p.is_file(): mism.append(f"{rel}: missing"); continue
        actual=cmd(repo,"git","hash-object",rel)
        allowed = WORKFLOW_BRANCH_BLOB if rel==WORKFLOW_PATH else expected
        if actual != allowed: mism.append(f"{rel}: expected {allowed}, found {actual}")
    for rel in SOURCE.get("required_absent",[]):
        if (repo/rel).exists(): mism.append(f"{rel}: expected absent")
    if mism: raise RuntimeError("source fingerprint mismatch; no audit edits applied:\n- "+"\n- ".join(mism))
    workflow=(repo/WORKFLOW_PATH).read_text()
    if "whoop_ui_contract_audit.py" not in workflow: raise RuntimeError("WHOOP UI audit line missing from branch workflow")

def stage(repo: Path):
    staged={rel:text for rel,text in ADDS.items()}
    for rel in staged:
        if (repo/rel).exists(): raise RuntimeError(f"new file already exists: {rel}")
    for op in PATCH["operations"]:
        rel=op["path"]
        cur=staged.get(rel)
        if cur is None: cur=(repo/rel).read_text()
        if op["type"]=="replace_once": cur=replace_once(cur,op["old"],op["new"],rel,op.get("note",""))
        elif op["type"]=="replace_between": cur=replace_between(cur,op["start"],op["end"],op["new"],rel,op.get("note",""))
        else: raise RuntimeError(f"unknown op {op['type']}")
        staged[rel]=cur
    deletes=list(PATCH.get("deletes",[]))
    for rel in deletes:
        if not (repo/rel).is_file(): raise RuntimeError(f"delete target missing: {rel}")
    for rel,tokens in PATCH.get("postconditions",{}).get("required",{}).items():
        text=staged.get(rel,(repo/rel).read_text())
        for token in tokens:
            if token not in text: raise RuntimeError(f"{rel}: missing postcondition {token!r}")
    for rel,tokens in PATCH.get("postconditions",{}).get("forbidden",{}).items():
        text=staged.get(rel,(repo/rel).read_text())
        for token in tokens:
            if token in text: raise RuntimeError(f"{rel}: forbidden postcondition remains {token!r}")
    return staged,deletes

def apply(repo: Path, staged, deletes):
    for rel,text in staged.items(): atomic_write(repo/rel,text)
    for rel in deletes: (repo/rel).unlink()
    cmd(repo,"git","diff","--check")

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("repo",type=Path); ap.add_argument("--check",action="store_true"); ap.add_argument("--apply",action="store_true")
    a=ap.parse_args(); repo=a.repo.resolve()
    if a.check==a.apply: raise RuntimeError("choose exactly one of --check or --apply")
    verify(repo); staged,deletes=stage(repo)
    if a.check:
        print(f"audit compatibility check passed; writes={len(staged)} deletes={len(deletes)}")
    else:
        apply(repo,staged,deletes); print(f"audit patch applied; writes={len(staged)} deletes={len(deletes)}")
if __name__=="__main__":
    try: main()
    except Exception as e:
        print(f"audit patch ERROR: {e}",file=sys.stderr); raise SystemExit(1)
