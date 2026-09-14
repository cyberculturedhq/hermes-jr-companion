"""Use an environment containing both Hermes dependencies and this companion."""
import os, sys, json, shutil, uuid
from pathlib import Path
import tempfile
if len(sys.argv) != 2:
 raise SystemExit('Usage: python Validation/native_hooks.py /path/to/hermes-agent')
hermes_source=Path(sys.argv[1]).resolve()
fixture=tempfile.TemporaryDirectory(prefix='hermes-jr-native-hooks-')
root=Path(fixture.name)
home=root/'home'
home.mkdir(exist_ok=True)
plugin=home/'plugins/hermes-jr'
plugin.mkdir(parents=True,exist_ok=True)
source=Path(__file__).resolve().parents[1]/'plugin'
for name in ['plugin.yaml','__init__.py']:
 shutil.copy2(source/name,plugin/name)
(home/'config.yaml').write_text('plugins:\n  enabled:\n    - hermes-jr\n')
os.environ['HERMES_HOME']=str(home)
os.environ['HERMES_JR_STATE_DIR']=str(root/('state-'+uuid.uuid4().hex))
os.environ['HERMES_BUNDLED_PLUGINS']=str(root/'no-bundled-plugins')
os.environ['HERMES_PROFILE']='default'
sys.path.insert(0,str(hermes_source))
from hermes_jr.state import State
state=State()
did=str(uuid.uuid4())
state.add_device(did,'fixture','fake-service',paired=True)
state.settings({'push_enabled':True})
state.set_push(did,True)
from hermes_cli.profiles import get_active_profile_name
state.follow(did,get_active_profile_name(),'fixture-session')
from hermes_cli.lifecycle import invoke_hook
invoke_hook('on_session_end',session_id='fixture-session',task_id='task',turn_id='turn',completed=True,failed=False,interrupted=False,turn_exit_reason='text_response(stop)',model='fixture',platform='cli')
invoke_hook('on_session_end',session_id='fixture-session',task_id='task',turn_id='turn',completed=True,failed=False,interrupted=False)
invoke_hook('pre_approval_request',session_id='fixture-session',request_id='approval',surface='cli')
invoke_hook('pre_tool_call',tool_name='clarify',session_id='fixture-session',tool_call_id='clarify')
events=state.outbox()
kinds=sorted(x['kind'] for x in events)
print(json.dumps({'native_hook_events':kinds,'deduplicated':len(events)==3}))
assert kinds==['approval','clarification','completed'],kinds

fixture.cleanup()
