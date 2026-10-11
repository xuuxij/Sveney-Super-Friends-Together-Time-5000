"""Publishes a sanitized export of this repo to GitHub and attaches the pack zip to a release.

  python -I tools/publish/publish.py [--dry-run] [--private] [-m "message"] [--notes-extra "text"]

The export lives in a sibling folder, <repo parent>/<pack name>-publish, with its own git history:
tracked files only, committed as the GitHub no-reply identity with UTC dates, after an audit for
personal strings in the files and in the zip. The first run creates the GitHub repository named in
config/pack.json (updates.repository); every run pushes and creates or refreshes the release
v<version> with dist/<pack name>-v<version>.zip attached. If updates.repository no longer matches the
export's origin (the pack was renamed), the GitHub repository is renamed first; GitHub redirects the
old links. Nothing here touches the working repo.
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
PARENT = os.path.dirname(ROOT)
LEGACY_STAGING = ('FFWModpack-publish',)   # export folder names from before the pack was renamed
IDENTITY = ('xuuxij', '20761916+xuuxij@users.noreply.github.com')

# Anything matching one of these must not leave this machine.
AUDIT = [re.compile(p, re.I) for p in (
    r'colinmcman', r'\bcolin\b', r'um-pc', r'gmail', r'192\.168\.\d+\.\d+', r'\b10\.\d+\.\d+\.\d+\b',
    r'claude\.ai', r'co-authored-by', r'claude-session', r'users\\[a-z]', r'/users/[a-z]',
)]
AUDIT_SKIP_EXT = {'.dll', '.exe', '.pak', '.ucas', '.utoc', '.png', '.jpg', '.jpeg'}


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


def origin_repo(staging):
    """owner/name of the export's origin remote, or None."""
    r = run(['git', 'remote', 'get-url', 'origin'], cwd=staging, check=False)
    m = re.search(r'github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?/?$', r.stdout.strip()) if r.returncode == 0 else None
    return m.group(1) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--private', action='store_true', help='create the repository private (first run only)')
    ap.add_argument('-m', '--message', default=None)
    ap.add_argument('--notes-extra', default=None, help='extra paragraph for the release notes (new release only)')
    a = ap.parse_args()

    cfg = json.load(open(os.path.join(ROOT, 'config', 'pack.json'), encoding='utf-8'))
    repo = cfg['updates']['repository']
    title = cfg.get('title', cfg['name'])
    version = cfg['version']
    zip_name = '%s-v%s.zip' % (cfg['name'], version)
    zip_path = os.path.join(ROOT, 'dist', zip_name)
    if not os.path.exists(zip_path):
        raise SystemExit('build the pack first: ' + zip_path)
    with zipfile.ZipFile(zip_path) as z:
        manifest = json.loads(z.read('%s-v%s/pack/manifest.json' % (cfg['name'], version)))
    if manifest['version'] != version:
        raise SystemExit('zip manifest says %s, pack.json says %s' % (manifest['version'], version))
    description = 'Far Far West co-op modpack (%s): one installer, identical files for everyone' % title

    # --- export tracked files --------------------------------------------
    staging = os.path.join(PARENT, cfg['name'] + '-publish')
    for old in LEGACY_STAGING:
        legacy = os.path.join(PARENT, old)
        if not os.path.isdir(staging) and os.path.isdir(legacy):
            os.rename(legacy, staging)
            print('export folder renamed: %s -> %s' % (old, os.path.basename(staging)))
    files = run(['git', 'ls-files'], cwd=ROOT).stdout.split()
    os.makedirs(staging, exist_ok=True)
    for entry in os.listdir(staging):
        if entry == '.git':
            continue
        p = os.path.join(staging, entry)
        shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
    for rel in files:
        src = os.path.join(ROOT, rel)
        dst = os.path.join(staging, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)

    # --- audit --------------------------------------------------------------
    hits = []
    for rel in files:
        if os.path.splitext(rel)[1].lower() in AUDIT_SKIP_EXT:
            continue
        audit_bytes(rel, open(os.path.join(staging, rel), 'rb').read(), hits)
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            if os.path.splitext(info.filename)[1].lower() in AUDIT_SKIP_EXT:
                continue
            audit_bytes('zip:' + info.filename, z.read(info), hits)
    if os.path.isdir(os.path.join(staging, '.git')):
        log = run(['git', 'log', '--format=%an <%ae> %ad', '--date=iso-strict'], cwd=staging, check=False).stdout
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
        print('dry run: export is in', staging)
        return

    # --- commit as the no-reply identity, UTC ---------------------------------
    if not os.path.isdir(os.path.join(staging, '.git')):
        run(['git', 'init', '-q', '-b', 'main'], cwd=staging)
    run(['git', 'config', 'user.name', IDENTITY[0]], cwd=staging)
    run(['git', 'config', 'user.email', IDENTITY[1]], cwd=staging)
    run(['git', 'add', '-A'], cwd=staging)
    now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S+00:00')
    env = dict(os.environ, GIT_AUTHOR_DATE=now, GIT_COMMITTER_DATE=now)
    msg = a.message or ('Pack %s' % version)
    staged = run(['git', 'diff', '--cached', '--quiet'], cwd=staging, check=False).returncode != 0
    if staged:
        run(['git', 'commit', '-q', '-m', msg], cwd=staging, env=env)
        print('committed:', msg)
    else:
        print('nothing new to commit')
    print(run(['git', 'log', '-1', '--format=%h %an <%ae> %ad', '--date=iso-strict'], cwd=staging).stdout.strip())

    # --- repository (create, or rename to follow the pack) + push -------------
    current = origin_repo(staging)
    if not current:
        vis = '--private' if a.private else '--public'
        run(['gh', 'repo', 'create', repo, vis, '--source', staging, '--remote', 'origin', '--push',
             '--description', description])
        print('created https://github.com/%s (%s)' % (repo, vis.strip('-')))
    else:
        if current.lower() != repo.lower():
            run(['gh', 'repo', 'rename', repo.split('/')[1], '-R', current, '--yes'])
            run(['git', 'remote', 'set-url', 'origin', 'https://github.com/%s.git' % repo], cwd=staging)
            run(['gh', 'repo', 'edit', repo, '--description', description])
            print('renamed https://github.com/%s -> https://github.com/%s (old links redirect)' % (current, repo))
        run(['git', 'push', '-q', 'origin', 'main'], cwd=staging)
        print('pushed to https://github.com/%s' % repo)

    # --- release with the zip -------------------------------------------------
    tag = 'v' + version
    notes = ('%s, made for Far Far West %s. Fingerprint %s.\n\n'
             'Close the game, extract the zip, double-click Install.bat, then Verify.bat (must say OK with the fingerprint above). '
             'Update.bat installs newer packs later; Uninstall.bat removes everything.' % (title, manifest['game']['productVersion'], manifest['fingerprint']))
    if a.notes_extra:
        notes += '\n\n' + a.notes_extra
    exists = run(['gh', 'release', 'view', tag, '-R', repo], check=False).returncode == 0
    if exists:
        run(['gh', 'release', 'upload', tag, zip_path, '--clobber', '-R', repo])
        print('release %s: zip replaced' % tag)
    else:
        run(['gh', 'release', 'create', tag, zip_path, '-R', repo, '--title', '%s %s' % (title, tag), '--notes', notes, '--latest'])
        print('release %s created with %s' % (tag, zip_name))
    print('download: https://github.com/%s/releases/latest' % repo)


if __name__ == '__main__':
    main()
