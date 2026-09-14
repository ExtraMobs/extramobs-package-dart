"""Fetch the pinned OpenSSL LTS source; never execute unverified downloads."""
from pathlib import Path
import hashlib
import sys
import tarfile
import urllib.request

VERSION = '3.5.8'
SHA256 = 'a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2'

def fetch(directory):
    root = Path(directory).resolve()
    root.mkdir(parents=True, exist_ok=True)
    archive = root / f'openssl-{VERSION}.tar.gz'
    if not archive.exists():
        urllib.request.urlretrieve(
            f'https://github.com/openssl/openssl/releases/download/openssl-{VERSION}/{archive.name}', archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError('OpenSSL SHA-256 mismatch')
    source = root / f'openssl-{VERSION}'
    if not source.exists():
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                target = (root / member.name).resolve()
                if root not in target.parents or member.issym() or member.islnk():
                    raise RuntimeError('Unsafe source archive member')
            tar.extractall(root)
    return source

if __name__ == '__main__':
    print(fetch(sys.argv[1]))
