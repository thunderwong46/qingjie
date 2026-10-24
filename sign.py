#!/usr/bin/env python3
"""Sign with the existing, certificate-pinned local identity. Never fall back to ad hoc."""
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

config_path = Path(os.environ.get('LIGHTSHOT_SIGNING_CONFIG', str(Path.home() / 'Library/Application Support/LightShotSigning/signing.json')))
if not config_path.is_file():
    raise SystemExit('Missing fixed local signing identity. Stop: ad-hoc signing would invalidate screen permissions.')
config = json.loads(config_path.read_text())
password = Path(config['passwordFile']).read_text()
keychain = config['keychain']
identity = config['identity']

def run(args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        raise SystemExit(result.stderr.strip() or result.stdout.strip())
    return result.stdout

old_search = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']))
run(['/usr/bin/security', 'unlock-keychain', '-p', password, keychain])
try:
    # macOS identity resolution also consults the user's search list, even with --keychain.
    run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', keychain, *[p for p in old_search if p != keychain]])
    requirement = f'designated => identifier "local.thunder.lightshot" and certificate leaf = H"{identity}"'
    run(['/usr/bin/codesign', '--force', '--sign', identity, '--keychain', keychain,
         '--timestamp=none', '--identifier', 'local.thunder.lightshot', '--requirements', '=' + requirement, sys.argv[1]])
    run(['/usr/bin/codesign', '--verify', '--strict', sys.argv[1]])
finally:
    run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *old_search])
    run(['/usr/bin/security', 'lock-keychain', keychain])
print('Signed with the fixed LightShot certificate; identity is independent of this build’s hash.')
