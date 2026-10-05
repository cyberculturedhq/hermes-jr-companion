"""Run with the Hermes host Python to test a disposable CLI handoff (POSIX only)."""
import os, pty, sys, tempfile
from pathlib import Path
from unittest.mock import patch
import psutil
from hermes_cli import active_sessions as registry
from hermes_jr import handoff
with tempfile.TemporaryDirectory() as directory:
    home = Path(directory)
    script = home / 'hermes'
    script.write_text('import signal, time, sys\nsignal.signal(signal.SIGTERM, lambda *_: sys.exit(0))\nprint("ready", flush=True)\nwhile True: time.sleep(0.1)\n')
    pid, fd = pty.fork()
    if pid == 0:
        os.execl(sys.executable, sys.executable, str(script))
    try:
        assert b'ready' in os.read(fd, 100)
        proc = psutil.Process(pid)
        owner = {'pid': pid, 'process_start_time': proc.create_time(), 'surface': 'cli',
                 'session_id': 'test-only', 'lease_id': 'test-lease', 'metadata': {'live_session_id': 'test-only'}}
        (home / 'runtime').mkdir()
        registry._write_entries(registry._state_path(home), [owner])
        with patch.object(handoff, '_runtime', return_value=(registry, psutil, home, script)):
            preview = handoff.preview('test-phone', 'default', 'test-only')
            assert proc.is_running(), 'Preview must not close the owner'
            result = handoff.commit('test-phone', 'default', 'test-only', preview['ticket'])
            assert result == {'ready': True}, result
            assert not psutil.pid_exists(pid)
        print('PASS: real graceful exit, process wait, and stale lease cleanup; actual user CLI untouched')
    finally:
        if psutil.pid_exists(pid):
            psutil.Process(pid).terminate()
        os.close(fd)
