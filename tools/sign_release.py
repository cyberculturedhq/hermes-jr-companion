#!/usr/bin/env python3
"""Print the release-body signature marker. Keep the private key outside this repository."""
import argparse
import base64
import sys
from pathlib import Path
from cryptography.hazmat.primitives.serialization import load_pem_private_key, Encoding, PublicFormat
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'plugin/src'))
from hermes_jr.release_signature import message, PUBLIC_KEY

parser = argparse.ArgumentParser()
parser.add_argument('--key', required=True, type=Path)
parser.add_argument('--version', required=True)
parser.add_argument('--commit', required=True)
args = parser.parse_args()
if args.key.stat().st_mode & 0o077:
    parser.error('Private key must have mode 0600')
key = load_pem_private_key(args.key.read_bytes(), password=None)
if key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw) != PUBLIC_KEY:
    parser.error('Key does not match the pinned release identity')
signature = base64.b64encode(key.sign(message(args.version, args.commit))).decode('ascii')
print(f'<!-- hermes-jr-release-v1: {signature} -->')
