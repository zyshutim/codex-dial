"""Package a signed release without local paths, private material or xattrs."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile


def package(app: Path, archive: Path):
    app = app.resolve(strict=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    files = []
    forbidden_suffixes = {'.key', '.pem', '.p12', '.pfx', '.keychain-db', '.sqlite', '.sqlite3', '.db', '.jsonl'}
    sensitive = re.compile(rb'/Users/[^/\x00\r\n]+/|-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----')
    for path in sorted(app.rglob('*')):
        if path.is_symlink():
            raise ValueError('Unexpected symlink: ' + str(path.relative_to(app)))
        if not path.is_file():
            continue
        if path.name == '.DS_Store' or path.name.startswith('._') or '__MACOSX' in path.parts:
            continue
        relative = path.relative_to(app)
        if path.suffix.lower() in forbidden_suffixes or path.name in {'auth.json', 'presets.json', 'keychain-password', '.env'}:
            raise ValueError('Private or runtime file in app: ' + str(relative))
        if sensitive.search(path.read_bytes()):
            raise ValueError('Local path or private key material in app: ' + str(relative))
        files.append(path)
    archive = archive.resolve()
    if archive.is_relative_to(app):
        raise ValueError('Archive must be outside the app bundle')
    archive.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=archive.parent, suffix='.zip', delete=False) as handle:
            temporary = Path(handle.name)
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as output:
            for path in files:
                output.write(path, Path(app.name) / path.relative_to(app))
        os.replace(temporary, archive)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print('Packaged: ' + str(archive))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('archive', type=Path)
    args = parser.parse_args()
    package(args.app, args.archive)
