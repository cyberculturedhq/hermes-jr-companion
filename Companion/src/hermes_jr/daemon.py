"""Service entry point, with private bounded logs and explicit environment restoration."""
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import sys


def main():
    os.umask(0o077)
    directory = Path(sys.argv[1]).resolve()
    config = directory / 'service-environment.json'
    values = json.loads(config.read_text())
    for key in ('HERMES_HOME', 'HERMES_JR_DASHBOARD_TOKEN', 'HERMES_JR_DASHBOARD_SESSION_TOKEN'):
        os.environ.pop(key, None)
        if key in values:
            os.environ[key] = values[key]
    os.environ['HERMES_JR_STATE_DIR'] = str(directory)
    handler = RotatingFileHandler(directory / 'service.log', maxBytes=1_000_000, backupCount=2)
    handler.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
    logger = logging.getLogger('hermes_jr')
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False
    from .cli import dispatch
    import argparse
    logger.info('Companion service started')
    try:
        dispatch(argparse.Namespace(jr_command='run'))
    except BaseException:
        # Do not log raw exceptions: upstream errors may contain credentials.
        logger.error('Companion service stopped; check configuration with hermes jr doctor')
        raise SystemExit(1) from None
    finally:
        logger.info('Companion service stopped')


if __name__ == '__main__':
    main()
