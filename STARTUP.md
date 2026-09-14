# Automatic startup

After installing the plugin and running `hermes jr setup`, install one service for the shared companion state:

```sh
hermes jr service install
hermes jr doctor
hermes jr service status
```

Stop a foreground `hermes jr run` first. The installer verifies that the package is installed in the invoking Python environment. It installs a per-user launchd agent on macOS or a systemd user service on Linux, starts it now, and starts it at subsequent user logins. The supervisor restarts the bridge after a crash, with a ten-second delay. Relay connectivity separately retries with backoff after network loss.

The service runs the exact Python environment used during installation; keep that environment available. Reinstall the service after moving or replacing the Hermes Python environment. No root service, shell command evaluation, or broad environment copying is used. Each distinct state directory receives a separate service identifier; all profiles sharing one state directory share one bridge.

```sh
hermes jr service stop
hermes jr service start
hermes jr service restart
hermes jr service uninstall
```

`stop` stops the current service; it can start again at the next login. `uninstall` removes startup and its saved dashboard environment. Neither action deletes pairings or revokes phone access. Use `hermes jr revoke DEVICE_UUID` before removing access permanently.

## Dashboard and host availability

The host must be awake. On macOS the service starts after the user logs in, not before login or FileVault unlock. On Linux, startup without an interactive login requires the administrator to enable lingering for the user; this installer does not change that policy. Linux requires an available systemd user manager. Containers, WSL installations without systemd, and other platforms can supervise `hermes jr run` externally.

The companion does not start a second dashboard or gateway. Use Hermes' existing gateway/dashboard supervision and keep the configured dashboard on loopback. Recent Hermes supports `hermes gateway status`, `hermes gateway install`, and `hermes gateway start`; inspect your installation and its existing service before changing it. Schedule any needed Hermes restart after current work finishes. The companion can start before the dashboard and connect when the dashboard becomes available.

## Credentials and diagnostics

Dashboard credentials supplied through `HERMES_JR_DASHBOARD_TOKEN` or `HERMES_JR_DASHBOARD_SESSION_TOKEN` are saved privately in `service-environment.json` under the companion state directory. They are not placed in the service definition, shell arguments, or logs. Rerun service installation after stopping the bridge to save changed credentials. Normal loopback token bootstrapping needs no saved credential.

Logs live at the path shown by `service status` and rotate at one megabyte with two backups. They contain fixed status messages, not raw network exceptions or notification content. `hermes jr doctor` checks the relay's protocol and dashboard authentication/plugin availability. It does not read conversations or send a test push. The running bridge refreshes these health results periodically; status includes their timestamp so stale results are identifiable.

Service startup success means the process acquired its exclusive bridge lock. Check `doctor` for actual connectivity; a running process does not imply an available dashboard, Internet connection, or Apple delivery.

References: [Apple launchd jobs](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html) and [systemd service behavior](https://github.com/systemd/systemd/blob/main/man/systemd.service.xml).
