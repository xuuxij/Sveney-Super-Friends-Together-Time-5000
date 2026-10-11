"""Publishes a sanitized export of this repo to GitHub and attaches the pack zip to a release.

  python -I tools/publish/publish.py [--dry-run] [--private] [-m "message"]

The export lives in a sibling folder, <repo parent>/FFWModpack-publish, with its own git history:
tracked files only, committed as the GitHub no-reply identity with UTC dates, after an audit for
personal strings in the files and in the zip. The first run creates the GitHub repository named in
config/pack.json (updates.repository); every run pushes and creates or refreshes the release
v<version> with dist/FFWModpack-v<version>.zip attached. Nothing here touches the working repo.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
STAGING = os.path.join(os.path.dirname(ROOT), 'FFWModpack-publish')
IDENTITY = ('xuuxij', '20761916+xuuxij@users.noreply.github.com')

# Anything matching one of these must not leave this machine.
AUDIT = [re.compile(p, re.I) for p in (
    r'colinmcman', r'\bcolin\b', r'um-pc', r'gmail', r'192\.168\.\d+\.\d+', r'\b10\.\d+\.\d+\.\d+\b',
    r'claude\.ai', r'co-authored-by', r'claude-session', r'users\\[a-z]', r'/users/[a-z]',
)]
AUDIT_SKIP_EXT = {'.dll', '.exe', '.pak', '.ucas', '.utoc', '.png'}


def run(args, cwd=None, check=True, env=None):
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, env=env)
    if check and r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit('failed: ' + ' '.join(args))
    return r


def audit_bytes(label, data, hits):
    if not isinstance(data, str):
        try:
            data = data.decode('utf-8')
        except UnicodeDecodeError:
            data = data.decode('latin-1')
    for pat in AUDIT:
        for m in pat.finditer(data):
            if label.endswith('publish.py') and 'AUDIT' in data[max(0, m.start() - 200):m.start()]:
                continue  # the pattern list itself
            hits.append('%s: %s' % (label, data[max(0, m.start() - 30):m.end() + 30].replace(chr(10), ' ')))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--private', action='store_true', help='create the repository private (first run only)')
    ap.add_argument('-m', '--message', default=None)
    a = ap.parse_args()

    cfg = json.load(open(os.path.join(ROOT, 'config', 'pack.json'), encoding='utf-8'))
    repo = cfg['updates']['repository']
    version = cfg['version']
    zip_name = '%s-v%s.zip' % (cfg['name'], version)
    zip_path = os.path.join(ROOT, 'dist', zip_name)
    if not os.path.exists(zip_path):
        raise SystemExit('build the pack first: ' + zip_path)
    with zipfile.ZipFile(zip_path) as z:
        manifest = json.loads(z.read('%s-v%s/pack/manifest.json' % (cfg['name'], version)))
    if manifest['version'] != version:
        raise SystemExit('zip manifest says %s, pack.json says %s' % (manifest['version'], version))

    # --- export tracked files --------------------------------------------
    files = run(['git', 'ls-files'], cwd=ROOT).stdout.split()
    os.makedirs(STAGING, exist_ok=True)
    for entry in os.listdir(STAGING):
        if entry == '.git':
            continue
        p = os.path.join(STAGING, entry)
        shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
    for rel in files:
        src = os.path.join(ROOT, rel)
        dst = os.path.join(STAGING, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)

    # --- audit --------------------------------------------------------------
    hits = []
    for rel in files:
        if os.path.splitext(rel)[1].lower() in AUDIT_SKIP_EXT:
            continue
        audit_bytes(rel, open(os.path.join(STAGING, rel), 'rb').read(), hits)
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            if os.path.splitext(info.filename)[1].lower() in AUDIT_SKIP_EXT:
                continue
            audit_bytes('zip:' + info.filename, z.read(info), hits)
    if os.path.isdir(os.path.join(STAGING, '.git')):
        log = run(['git', 'log', '--format=%an <%ae> %ad', '--date=iso-strict'], cwd=STAGING, check=False).stdout
        for line in log.splitlines():
            if IDENTITY[1] not in line or not (line.endswith('+00:00') or line.endswith('Z')):  # git prints UTC as Z
                hits.append('git history: ' + line)
    if hits:
        print('AUDIT FAILED, nothing published:')
        for h in hits:
            print('  ' + h)
        raise SystemExit(1)
    print('audit clean: %d files, %s' % (len(files), zip_name))
    if a.dry_run:
        print('dry run: export is in', STAGING)
        return

    # --- commit as the no-reply identity, UTC ---------------------------------
    if not os.path.isdir(os.path.join(STAGING, '.git')):
        run(['git', 'init', '-q', '-b', 'main'], cwd=STAGING)
    run(['git', 'config', 'user.name', IDENTITY[0]], cwd=STAGING)
    run(['git', 'config', 'user.email', IDENTITY[1]], cwd=STAGING)
    run(['git', 'add', '-A'], cwd=STAGING)
    now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S+00:00')
    env = dict(os.environ, GIT_AUTHOR_DATE=now, GIT_COMMITTER_DATE=now)
    msg = a.message or ('Pack %s' % version)
    staged = run(['git', 'diff', '--cached', '--quiet'], cwd=STAGING, check=False).returncode != 0
    if staged:
        run(['git', 'commit', '-q', '-m', msg], cwd=STAGING, env=env)
        print('committed:', msg)
    else:
        print('nothing new to commit')
    print(run(['git', 'log', '-1', '--format=%h %an <%ae> %ad', '--date=iso-strict'], cwd=STAGING).stdout.strip())

    # --- repository + push ----------------------------------------------------
    has_origin = run(['git', 'remote'], cwd=STAGING).stdout.split()
    if 'origin' not in has_origin:
        vis = '--private' if a.private else '--public'
        run(['gh', 'repo', 'create', repo, vis, '--source', STAGING, '--remote', 'origin', '--push',
             '--description', 'Far Far West co-op modpack: one installer, identical files for everyone'])
        print('created https://github.com/%s (%s)' % (repo, vis.strip('-')))
    else:
        run(['git', 'push', '-q', 'origin', 'main'], cwd=STAGING)
        print('pushed to https://github.com/%s' % repo)

    # --- release with the zip -------------------------------------------------
    tag = 'v' + version
    notes = ('Made for Far Far West %s. Fingerprint %s.\n\n'
             'Close the game, extract the zip, double-click Install.bat, then Verify.bat (must say OK with the fingerprint above). '
             'Update.bat installs newer packs later; Uninstall.bat removes everything.' % (manifest['game']['productVersion'], manifest['fingerprint']))
    exists = run(['gh', 'release', 'view', tag, '-R', repo], check=False).returncode == 0
    if exists:
        run(['gh', 'release', 'upload', tag, zip_path, '--clobber', '-R', repo])
        print('release %s: zip replaced' % tag)
    else:
        run(['gh', 'release', 'create', tag, zip_path, '-R', repo, '--title', '%s %s' % (cfg['name'], tag), '--notes', notes, '--latest'])
        print('release %s created with %s' % (tag, zip_name))
    print('download: https://github.com/%s/releases/latest' % repo)


if __name__ == '__main__':
    main()
