"""Write a fresh Ed25519 setup signing key privately; never print the secret."""
import base64
import os
from pathlib import Path
import subprocess
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: python3 Scripts/create-setup-signing-key.py /private/path/setup-key.txt")
path = Path(sys.argv[1]).expanduser().resolve()
# OpenSSL ships with macOS and avoids modifying the user's Python environment.
private = subprocess.check_output(["openssl", "genpkey", "-algorithm", "ED25519", "-outform", "DER"])
descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w") as output:
    output.write(base64.urlsafe_b64encode(private).decode().rstrip("=") + "\n")
print("Created a private setup signing key at " + str(path))
