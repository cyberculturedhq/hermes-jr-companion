"""Isolated UI harness that restores a localhost connection through the real root view."""
import json
import sys
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="hermes-notification-ui-"))
project = root / "Hermes.xcodeproj"
(project / "xcshareddata/xcschemes").mkdir(parents=True)
d = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(repo / "Hermes.xcodeproj/project.pbxproj")]))
o = d["objects"]
t = o["F2773B8D1A9D145C836C926B"]
t["productType"] = "com.apple.product-type.bundle.ui-testing"
t["name"] = t["productName"] = "HermesUITests"
o[t["productReference"]]["path"] = "HermesUITests.xctest"
o[t["fileSystemSynchronizedGroups"][0]]["path"] = "HermesUITests"
for cfg in o[t["buildConfigurationList"]]["buildConfigurations"]:
    b = o[cfg]["buildSettings"]
    b.pop("TEST_HOST", None)
    b.pop("BUNDLE_LOADER", None)
    b["TEST_TARGET_NAME"] = "Hermes"
    b["PRODUCT_BUNDLE_IDENTIFIER"] = "com.hermesjr.app.uitests"
(project / "project.pbxproj").write_bytes(plistlib.dumps(d))
s = (repo / "Hermes.xcodeproj/xcshareddata/xcschemes/Hermes.xcscheme").read_text().replace("HermesTests", "HermesUITests")
(project / "xcshareddata/xcschemes/Hermes.xcscheme").write_text(s)
(root / "Hermes").mkdir()
for path in (repo / "Hermes").iterdir():
    if path.name != "HermesApp.swift":
        if path.is_dir():
            shutil.copytree(path, root / "Hermes" / path.name)
        else:
            (root / "Hermes" / path.name).symlink_to(path)
shutil.copy2(repo / ("Validation/GuidedUpdateFixture.swift" if "--guided-update" in sys.argv else "Validation/NotificationNavigationFixture.swift"), root / "Hermes/HermesApp.swift")
for name in ["HermesNotificationService", "SharedNotifications"]:
    (root / name).symlink_to(repo / name, target_is_directory=True)
(root / "HermesUITests").mkdir()
shutil.copy2(repo / ("Validation/GuidedUpdateUI.swift" if "--guided-update" in sys.argv else "Validation/NotificationNavigationUI.swift"), root / "HermesUITests")
print(project)
