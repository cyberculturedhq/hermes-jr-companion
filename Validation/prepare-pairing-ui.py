"""Create an isolated UI-test project; never change the production Xcode project.

Run with a fresh simulator. Build/test the printed project using xcodebuild.
Keep normal simulator signing enabled: disabling it omits the simulated Keychain
access-group entitlements required by the real app's setup credential storage.
Serve the observed agent code as plain text at http://127.0.0.1:18139/code.
The UI test compares that code to the real screen before confirming. Read the
app's copied prompt with simctl pbpaste and give it to the real Hermes agent.
"""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

repo=Path(__file__).resolve().parents[1]
root=Path(tempfile.mkdtemp(prefix='hermes-pairing-ui-'))
project=root/'Hermes.xcodeproj'
(project/'xcshareddata/xcschemes').mkdir(parents=True)
d=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(repo/'Hermes.xcodeproj/project.pbxproj')]))
o=d['objects'];t=o['F2773B8D1A9D145C836C926B']
t['productType']='com.apple.product-type.bundle.ui-testing';t['name']=t['productName']='HermesUITests'
o[t['productReference']]['path']='HermesUITests.xctest'
o[t['fileSystemSynchronizedGroups'][0]]['path']='HermesUITests'
for cfg in o[t['buildConfigurationList']]['buildConfigurations']:
 b=o[cfg]['buildSettings'];b.pop('TEST_HOST',None);b.pop('BUNDLE_LOADER',None)
 b['TEST_TARGET_NAME']='Hermes';b['PRODUCT_BUNDLE_IDENTIFIER']='com.hermesjr.app.uitests'
(project/'project.pbxproj').write_bytes(plistlib.dumps(d))
s=(repo/'Hermes.xcodeproj/xcshareddata/xcschemes/Hermes.xcscheme').read_text().replace('HermesTests','HermesUITests')
(project/'xcshareddata/xcschemes/Hermes.xcscheme').write_text(s)
for name in ['Hermes','HermesNotificationService','SharedNotifications']:(root/name).symlink_to(repo/name,target_is_directory=True)
(root/'HermesUITests').mkdir();shutil.copy2(repo/'Validation/PairingUI.swift',root/'HermesUITests/PairingUI.swift')
print(project)
