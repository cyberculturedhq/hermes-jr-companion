"""Run on a logged-in macOS desktop using an installed companion environment."""
import json, os, signal, subprocess, time
from pathlib import Path
from hermes_jr.state import State
from hermes_jr.supervisor import Supervisor
import tempfile
fixture = tempfile.TemporaryDirectory(prefix='hermes-jr-service-check-')
root=Path(fixture.name)
state=State(root/'state')
# This offline test never registers a real installation or sends a push.
state.settings({'host_token':'offline-fixture-only', 'relay_enabled':False, 'push_enabled':False,
                'update_checks_enabled':False,'service_url':'http://127.0.0.1:1','dashboard_url':'http://127.0.0.1:1'})
manager=Supervisor(state,home=root/'home')
checks=[]
try:
 manager.install()
 checks.append(('started',manager.status()['bridge_running']))
 def pid():
  value=manager.command(['launchctl','print',f'{manager.domain}/{manager.label}']).stdout
  import re
  return int(re.search(r'\bpid = (\d+)',value).group(1))
 original=pid()
 os.kill(original,signal.SIGKILL)
 deadline=time.monotonic()+25
 recovered=False
 while time.monotonic()<deadline:
  time.sleep(1)
  try:
   if pid()!=original and manager.status()['bridge_running']:
    recovered=True;break
  except (ValueError,AttributeError):pass
 checks.append(('restarted_after_crash',recovered))
 manager.stop()
 checks.append(('stopped',not manager.status()['bridge_running']))
 manager.start()
 checks.append(('started_again',manager.status()['bridge_running']))
finally:
 manager.uninstall()
 checks.append(('uninstalled',not manager.path.exists() and not manager.status()['manager_active']))
 checks.append(('state_preserved',state.get('host_token')=='offline-fixture-only'))
fixture.cleanup()
print(json.dumps(checks))
assert all(ok for _,ok in checks)
