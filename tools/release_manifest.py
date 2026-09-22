#!/usr/bin/env python3
"""Turn an authorized release into the small public update feed asset."""
import argparse
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'plugin/src'))
from hermes_jr.release_signature import signature_from_body, verify

parser = argparse.ArgumentParser()
parser.add_argument('--version', required=True)
parser.add_argument('--commit', required=True)
parser.add_argument('--body', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
release = {'latest': args.version, 'commit': args.commit, 'signature': signature_from_body(args.body.read_text())}
verify(release)
args.output.write_text(json.dumps({'schema': 1, 'version': args.version, 'commit': args.commit, 'signature': release['signature']}) + '\n')
