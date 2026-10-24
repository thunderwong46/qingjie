#!/usr/bin/env python3
"""One-time local signing setup. Never replaces an existing identity."""
import json, os, secrets, shlex, subprocess, tempfile
from pathlib import Path

support = Path.home() / 'Library/Application Support/LightShotSigning'
support.mkdir(mode=0o700, parents=True, exist_ok=True)
os.chmod(support, 0o700)
config_path = support / 'signing.json'
if config_path.exists():
    print('Existing dedicated signing identity found; preserving it.')
    raise SystemExit(0)
keychain = support / 'LightShotSigning.keychain-db'
password_path = support / 'keychain-password'
if keychain.exists() or password_path.exists():
    raise SystemExit('Dedicated keychain already exists without configuration; stop for inspection.')
password = secrets.token_urlsafe(36)
password_path.write_text(password)
os.chmod(password_path, 0o600)

def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode:
        # Do not print command arguments: some contain newly generated passwords.
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout

old_search = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']))
with tempfile.TemporaryDirectory(prefix='identity-', dir=support) as temp:
    temp = Path(temp)
    conf = temp / 'certificate.cnf'
    conf.write_text('''[req]\nprompt = no\ndistinguished_name = subject\nx509_extensions = extensions\n[subject]\nCN = LightShot Local Code Signing\n[extensions]\nbasicConstraints = critical,CA:false\nkeyUsage = critical,digitalSignature\nextendedKeyUsage = critical,codeSigning\nsubjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid\n''')
    private = temp / 'private.pem'
    certificate = temp / 'certificate.pem'
    run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-days', '3650', '-config', str(conf), '-keyout', str(private), '-out', str(certificate)])
    os.chmod(private, 0o600)
    bundle = temp / 'identity.p12'
    run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(private), '-in', str(certificate), '-name', 'LightShot Local Code Signing', '-out', str(bundle), '-passout', 'stdin'], input=password+'\n')
    os.chmod(bundle, 0o600)
    try:
        run(['/usr/bin/security', 'create-keychain', '-p', password, str(keychain)])
    finally:
        run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *old_search])
    run(['/usr/bin/security', 'unlock-keychain', '-p', password, str(keychain)])
    run(['/usr/bin/security', 'import', str(bundle), '-k', str(keychain), '-P', password, '-x', '-T', '/usr/bin/codesign'])
    run(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, str(keychain)])
    fingerprint = run(['/usr/bin/openssl', 'x509', '-in', str(certificate), '-noout', '-fingerprint', '-sha1']).strip().split('=')[-1].replace(':', '')
    config_path.write_text(json.dumps({'identity': fingerprint, 'keychain': str(keychain), 'passwordFile': str(password_path)}, indent=2))
    os.chmod(config_path, 0o600)
    (support / 'certificate.pem').write_bytes(certificate.read_bytes())
run(['/usr/bin/security', 'lock-keychain', str(keychain)])
print('Created dedicated local code-signing identity; private key is non-extractable in its own keychain.')
print('Certificate trust settings and existing keychains were not changed.')
