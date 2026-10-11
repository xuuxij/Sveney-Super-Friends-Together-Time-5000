"""Builds the pack's Blueprint-fix pak (ZZZ_FFWModpack_P) from the installed game's own files.

  python -I tools/morepak/build_morepak.py [--game <FarFarWest root>] [--out <dir>] [--keep]

Steps: unzip the pinned retoc (hash-checked), convert the vanilla assets listed in patches.json
from the game's IoStore containers to legacy form, verify their hashes, apply the byte patches
(each verified against the expected vanilla bytes), convert back to an IoStore container.
Output: <out>/FarFarWest/Content/Paks/~mods/ZZZ_FFWModpack_P.{utoc,ucas,pak}
Exit code is non-zero if anything does not match; nothing is written to the game folder.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def run(args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit('command failed: ' + ' '.join(args))
    return r.stdout + r.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--game', default=r'C:\Program Files (x86)\Steam\steamapps\common\FarFarWest')
    ap.add_argument('--out', default=os.path.join(ROOT, 'dist', '_morepak'))
    ap.add_argument('--keep', action='store_true', help='keep the temporary legacy assets for inspection')
    a = ap.parse_args()

    cfg = json.load(open(os.path.join(ROOT, 'config', 'pack.json'), encoding='utf-8'))
    spec = json.load(open(os.path.join(HERE, 'patches.json'), encoding='utf-8'))
    mp = cfg['morepak']

    exe = os.path.join(a.game, cfg['game']['exeRelativePath'].replace('/', os.sep))
    if not os.path.exists(exe):
        raise SystemExit('game not found: ' + exe)
    if sha256(exe).upper() != cfg['game']['exeSha256'].upper():
        raise SystemExit('the game exe differs from config/pack.json (game updated?) - re-verify before building')
    if spec['game'] != cfg['game']['productVersion']:
        raise SystemExit('patches.json was made for game %s, pack.json says %s' % (spec['game'], cfg['game']['productVersion']))

    zip_path = os.path.join(ROOT, 'vendor', 'retoc', mp['retocAsset'])
    if sha256(zip_path).lower() != mp['retocSha256'].lower():
        raise SystemExit('retoc zip hash mismatch: ' + zip_path)
    work = os.path.join(ROOT, 'dist', '_morepak_work')
    if os.path.exists(work):
        shutil.rmtree(work)
    os.makedirs(work)
    with zipfile.ZipFile(zip_path) as z:
        z.extract('retoc.exe', os.path.join(work, 'retoc'))
    retoc = os.path.join(work, 'retoc', 'retoc.exe')

    paks = os.path.join(a.game, 'FarFarWest', 'Content', 'Paks')
    legacy = os.path.join(work, 'legacy')
    patched = os.path.join(work, 'patched')
    os.makedirs(legacy)
    os.makedirs(patched)

    total = 0
    for asset in spec['assets']:
        rel = asset['path']
        base = rel.rsplit('/', 1)[1]
        run([retoc, 'to-legacy', '--no-shaders', '-f', rel + '.uasset', paks, legacy])
        src_uasset = os.path.join(legacy, rel.replace('/', os.sep) + '.uasset')
        src_uexp = os.path.join(legacy, rel.replace('/', os.sep) + '.uexp')
        if not os.path.exists(src_uexp):
            raise SystemExit('retoc did not produce ' + src_uexp)
        for p, want in ((src_uasset, asset['uassetSha256']), (src_uexp, asset['uexpSha256'])):
            got = sha256(p)
            if got != want.lower():
                raise SystemExit('%s: vanilla hash %s, expected %s (game updated? re-derive patches.json)' % (os.path.basename(p), got, want))
        data = bytearray(open(src_uexp, 'rb').read())
        for patch in asset['patches']:
            off = int(patch['offset'], 16)
            expect = bytes.fromhex(patch['expect'])
            new = bytes.fromhex(patch['set'])
            if len(expect) != len(new):
                raise SystemExit('%s @%s: expect/set length differ' % (base, patch['offset']))
            if bytes(data[off:off + len(expect)]) != expect:
                raise SystemExit('%s @%s: found %s, expected %s' % (base, patch['offset'], data[off:off + len(expect)].hex(), patch['expect']))
            data[off:off + len(new)] = new
            total += 1
        dst_dir = os.path.join(patched, os.path.dirname(rel.replace('/', os.sep)))
        os.makedirs(dst_dir, exist_ok=True)
        shutil.copyfile(src_uasset, os.path.join(patched, rel.replace('/', os.sep) + '.uasset'))
        open(os.path.join(patched, rel.replace('/', os.sep) + '.uexp'), 'wb').write(data)
        print('  %-40s %d patch(es)' % (base, len(asset['patches'])))

    out_dir = os.path.join(a.out, 'FarFarWest', 'Content', 'Paks', '~mods')
    if os.path.exists(a.out):
        shutil.rmtree(a.out)
    os.makedirs(out_dir)
    utoc = os.path.join(out_dir, mp['name'] + '.utoc')
    log = run([retoc, 'to-zen', '--no-parallel', '--version', mp['engineVersion'], patched, utoc])  # no-parallel: same bytes on every build
    produced = sorted(os.listdir(out_dir))
    for ext in ('.utoc', '.ucas', '.pak'):
        if mp['name'] + ext not in produced:
            sys.stderr.write(log)
            raise SystemExit('retoc to-zen did not produce ' + mp['name'] + ext)
    print('Built %s in %s: %d assets, %d patches' % (mp['name'], out_dir, len(spec['assets']), total))
    for f in produced:
        print('  %s %d B' % (f, os.path.getsize(os.path.join(out_dir, f))))
    if not a.keep:
        shutil.rmtree(work)


if __name__ == '__main__':
    main()
