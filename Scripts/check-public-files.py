"""Reject private file names before publication. Content scanning runs separately."""
from pathlib import PurePosixPath
import subprocess
import sys

paths = subprocess.check_output(['git', 'ls-files', '-z']).decode().split('\0')
private_roots = {'Audit', 'Publishing', 'UXReview'}
private_suffixes = {'.p8', '.p12', '.pfx', '.pem', '.key', '.mobileprovision', '.keystore', '.jks'}
blocked = []
for value in filter(None, paths):
    path = PurePosixPath(value)
    name = path.name
    if (path.parts[0] in private_roots or path.suffix.lower() in private_suffixes
            or name in {'.netrc', 'credentials.json', '.dev.vars', '.env'}
            or (name.startswith(('.env.', '.dev.vars.')) and not name.endswith('.example'))):
        blocked.append(value)
if blocked:
    print('Private files are tracked. Remove these files before publication:')
    print('\n'.join(blocked))
    sys.exit(1)
print('Public file names passed.')
