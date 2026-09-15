"""Persistent publisher signing. Private material never belongs in the app/repo.

Uses a dedicated keychain, not a trusted system root. Recipients need only the app.
Ad-hoc signing is an explicit preview-only opt-in; never silently change identity.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import tempfile

BUNDLE_ID = 'dev.local.codexdial'
STATE = Path.home() / 'Library/Application Support/Codex Dial Signing'


def run(args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        # Never echo command arguments: signing tools can receive private data.
        raise RuntimeError(Path(args[0]).name + ': ' + result.stderr.strip())
    return result.stdout.strip()


def keychain(path, password, create=False):
    # Keep the random keychain password out of shell arguments/process listings.
    security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
    core = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    reference = ctypes.c_void_p()
    if create:
        operation = security.SecKeychainCreate
        operation.argtypes = [ctypes.c_char_p, ctypes.c_uint32, ctypes.c_void_p,
                              ctypes.c_bool, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        status = operation(os.fsencode(path), len(password), password, False, None, ctypes.byref(reference))
    else:
        security.SecKeychainOpen.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
        status = security.SecKeychainOpen(os.fsencode(path), ctypes.byref(reference))
    if status:
        raise RuntimeError('无法打开签名钥匙串，系统错误码 %s。' % status)
    try:
        security.SecKeychainUnlock.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_bool]
        status = security.SecKeychainUnlock(reference, len(password), password, True)
        if status:
            raise RuntimeError('无法解锁签名钥匙串，系统错误码 %s。' % status)
    finally:
        core.CFRelease.argtypes = [ctypes.c_void_p]
        core.CFRelease(reference)


def setup():
    if (STATE / 'identity.json').exists():
        print('沿用已有 Codex Dial 签名身份。')
        return
    if STATE.exists() and any(STATE.iterdir()):
        raise RuntimeError('签名目录已有文件但初始化未完成。请先检查并恢复已有身份，不要生成新证书。')
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    STATE.chmod(0o700)
    password = secrets.token_bytes(32).hex().encode()
    with (STATE / 'keychain-password').open('xb', opener=lambda name, flags: os.open(name, flags, 0o600)) as file:
        file.write(password)
    (STATE / 'keychain-password').chmod(0o600)
    chain = STATE / 'publisher.keychain-db'
    search_list = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']))
    try:
        keychain(chain, password, create=True)
    finally:
        # Creating a keychain must not change how other applications find keys.
        current = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']))
        if current != search_list:
            run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *search_list])
    with tempfile.TemporaryDirectory(prefix='certificate-', dir=STATE) as folder:
        temporary = Path(folder)
        config = temporary / 'openssl.cnf'
        config.write_text('[req]\ndistinguished_name=subject\nx509_extensions=extensions\nprompt=no\n'
                          '[subject]\nCN=Codex Dial Publisher\nO=Codex Dial\n'
                          '[extensions]\nbasicConstraints=critical,CA:false\n'
                          'keyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n'
                          'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n')
        private = temporary / 'private.pem'
        certificate = STATE / 'publisher.pem'
        run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256',
             '-days', '3650', '-config', str(config), '-keyout', str(private), '-out', str(certificate)])
        private.chmod(0o600)
        rsa_private = temporary / 'rsa-private.pem'
        run(['/usr/bin/openssl', 'rsa', '-in', str(private), '-out', str(rsa_private)])
        rsa_private.chmod(0o600)
        # Import PEM items directly: macOS and OpenSSL disagree on some PKCS#12 defaults.
        run(['/usr/bin/security', 'import', str(rsa_private), '-k', str(chain),
             '-T', '/usr/bin/codesign'])
        run(['/usr/bin/security', 'import', str(certificate), '-k', str(chain), '-t', 'cert'])
    der = subprocess.check_output(['/usr/bin/openssl', 'x509', '-in', str(certificate), '-outform', 'DER'])
    fingerprint = hashlib.sha1(der).hexdigest().upper()
    (STATE / 'identity.json').write_text(json.dumps({'sha1': fingerprint, 'bundleID': BUNDLE_ID}) + '\n')
    (STATE / 'identity.json').chmod(0o600)
    print('固定签名身份已建立：' + fingerprint)
    print('私有签名资料保存在仓库外：' + str(STATE))
    print('首次签名前还需完成 docs/SIGNING.md 中仅限 codesign 的用户信任设置。')


def sign(app):
    explicit = os.environ.get('CODEXDIAL_SIGNING_IDENTITY')
    if explicit:
        run(['/usr/bin/codesign', '--force', '--sign', explicit, '--identifier', BUNDLE_ID, str(app)])
    elif os.environ.get('CODEXDIAL_ADHOC') == '1':
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', BUNDLE_ID, str(app)])
        print('仅供预览：临时签名不会保留跨版本授权。')
    else:
        metadata = STATE / 'identity.json'
        if not metadata.exists():
            raise RuntimeError('缺少固定签名身份。先运行 python3 Scripts/sign_app.py --setup。'
                               '仅构建预览可显式设置 CODEXDIAL_ADHOC=1。')
        identity = json.loads(metadata.read_text())
        fingerprint = identity['sha1']
        if len(fingerprint) != 40 or any(c not in '0123456789ABCDEF' for c in fingerprint):
            raise RuntimeError('签名身份指纹无效，停止构建。')
        keychain(STATE / 'publisher.keychain-db', (STATE / 'keychain-password').read_bytes())
        requirement = 'designated => identifier "' + BUNDLE_ID + '" and certificate leaf = H"' + fingerprint + '"'
        try:
            run(['/usr/bin/codesign', '--force', '--sign', fingerprint, '--keychain', str(STATE / 'publisher.keychain-db'),
                 '--identifier', BUNDLE_ID, '--timestamp=none', '--requirements', '=' + requirement, str(app)])
        except RuntimeError as error:
            if 'no identity found' in str(error):
                raise RuntimeError('固定证书尚不可用于签名。请完成 docs/SIGNING.md 的一次性签名信任设置；'
                                   '不会回退到临时签名。') from error
            raise
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    print('签名验证通过：' + str(app))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--setup', action='store_true')
    parser.add_argument('--sign', type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.setup:
            setup()
        elif arguments.sign:
            sign(arguments.sign)
        else:
            parser.error('choose --setup or --sign APP')
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        parser.exit(1, str(error) + '\n')
