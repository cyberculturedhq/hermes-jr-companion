import base64
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from hermes_jr.release_signature import message
KEY = Ed25519PrivateKey.generate()
PUBLIC = KEY.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
def signature(version='0.3.0', commit='a'*40):
    return base64.b64encode(KEY.sign(message(version, commit))).decode('ascii')
def body():
    return f'<!-- hermes-jr-release-v1: {signature()} -->'
