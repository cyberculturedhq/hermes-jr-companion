"""Create an isolated project with real app code and local-network regression tests."""
from pathlib import Path
import shutil
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="hermes-notification-tests-"))
shutil.copytree(repo / "Hermes.xcodeproj", root / "Hermes.xcodeproj")
for name in ["Hermes", "HermesNotificationService", "SharedNotifications"]:
    (root / name).symlink_to(repo / name, target_is_directory=True)
shutil.copytree(repo / "HermesTests", root / "HermesTests")
shutil.copy2(repo / "Validation/NotificationNavigationTests.swift", root / "HermesTests")
shutil.copy2(repo / "Validation/GuidedUpdateFlowTests.swift", root / "HermesTests")
print(root / "Hermes.xcodeproj")
