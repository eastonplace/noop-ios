from pathlib import Path
from collections import Counter
import hashlib
import json
import subprocess
import sys

repo = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[3]
base = 'a7ade2598d439d33cd20816d69ccc991b29322fc'

def string_end(s, start):
    at = start
    while at < len(s) and s[at] == '#':
        at += 1
    hashes = s[start:at]
    if at >= len(s) or s[at] != '"':
        return None
    delimiter = '"""' if s.startswith('"""', at) else '"'
    at += len(delimiter)
    while at < len(s):
        if s.startswith(delimiter + hashes, at):
            return at + len(delimiter) + len(hashes)
        if s.startswith('\\' + hashes + '(', at):
            at = balanced_end(s, at + 2 + len(hashes))
        elif s.startswith('\\' + hashes, at):
            at += 2 + len(hashes)
        else:
            at += 1
    raise ValueError('Unterminated Swift string')

def comment_end(s, at):
    if s.startswith('//', at):
        end = s.find('\n', at)
        return len(s) if end < 0 else end
    if not s.startswith('/*', at):
        return None
    depth = 1
    at += 2
    while depth:
        if s.startswith('/*', at):
            depth += 1
            at += 2
        elif s.startswith('*/', at):
            depth -= 1
            at += 2
        else:
            at += 1
        if at >= len(s) and depth:
            raise ValueError('Unterminated comment')
    return at

def balanced_end(s, at):
    depth = 1
    while at < len(s):
        end = comment_end(s, at) or string_end(s, at)
        if end is not None:
            at = end
        elif s[at] == '(':
            depth += 1
            at += 1
        elif s[at] == ')':
            depth -= 1
            at += 1
            if depth == 0:
                return at
        else:
            at += 1
    raise ValueError('Unterminated interpolation')

def literals(s):
    result = []
    at = 0
    while at < len(s):
        end = comment_end(s, at)
        if end is not None:
            at = end
            continue
        end = string_end(s, at)
        if end is not None:
            result.append(s[at:end])
            at = end
        else:
            at += 1
    return result

report = {'base': base, 'files': []}
for path in sorted([*(repo / 'Strand/AI').rglob('*.swift'), *(repo / 'StrandiOS/Coach').rglob('*.swift')]):
    relative = str(path.relative_to(repo))
    old = subprocess.check_output(['git', 'show', f'{base}:{relative}'], cwd=repo).decode()
    new = path.read_text()
    before, after = Counter(literals(old)), Counter(literals(new))
    removed, added = before - after, after - before
    allowed = Counter({'"/chat/completions"': 1, '"/models"': 1}) if relative.endswith('/Providers/Custom.swift') else Counter()
    assert not removed, (relative, removed)
    assert added == allowed, (relative, added)
    report['files'].append({'file': relative, 'original_literal_count': sum(before.values()),
        'removed_or_changed_original_literals': 0, 'added_transport_path_literals': dict(added),
        'original_literals_sha256': hashlib.sha256('\0'.join(sorted(before.elements())).encode()).hexdigest(),
        'unchanged_entire_file': old == new})
report['result'] = 'PASS: every original cloud/on-device Coach string literal retained byte-for-byte; only two new endpoint path literals.'
output = Path(__file__).with_name('coach-prompt-literal-proof.json')
output.write_text(json.dumps(report, indent=2) + '\n')
print(report['result'])
print(f'{len(report["files"])} AI/Coach source files checked; proof: {output}')
