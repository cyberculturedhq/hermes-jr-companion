"""Pinned release authorization, independent of GitHub credentials and tag metadata."""
import base64
import re
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

PUBLIC_KEY = bytes.fromhex('ac072d31db546d1f241ac1ace40cb0b474bd4e833d78385cb9f03499e44778af')
REPOSITORY = 'cyberculturedhq/hermes-jr-companion'


def message(version, commit):
    if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', version) or not re.fullmatch('[0-9a-f]{40}', commit):
        raise ValueError('Invalid release identity')
    return f'hermes-jr-release-v1\n{REPOSITORY}\n{version}\n{commit}\n'.encode('ascii')


def verify(release):
    try:
        signature = base64.b64decode(release['signature'], validate=True)
        Ed25519PublicKey.from_public_bytes(PUBLIC_KEY).verify(signature, message(release['latest'], release['commit']))
    except (InvalidSignature, ValueError, KeyError, TypeError):
        raise ValueError('Release signature missing or invalid; no update was installed') from None


def signature_from_body(body):
    matches = re.findall(r'<!-- hermes-jr-release-v1: ([A-Za-z0-9+/]{86}==) -->', body or '')
    if len(matches) != 1:
        raise ValueError('Release signature missing or ambiguous')
    return matches[0]
