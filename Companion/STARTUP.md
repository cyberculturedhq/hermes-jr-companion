# Startup and troubleshooting

The Hermes backend and the companion bridge are separate services. Both must be available for the phone to connect. Services start after user login; the host must remain awake.

## Hermes backend

Reuse the existing supervisor for the configured loopback dashboard. If none exists, run these commands with the Python environment that runs Hermes:

```sh
PYTHON -m hermes_jr.cli backend install
PYTHON -m hermes_jr.cli backend status
PYTHON -m hermes_jr.cli doctor
```

`backend install` registers a dedicated `hermes serve` process with launchd on macOS or systemd --user on Linux. It returns after registration; `dashboard_rpc=ok` in doctor confirms actual readiness. It uses the configured HTTP port on 127.0.0.1 and the current Hermes profile. Existing listeners and differing service definitions are preserved.

If the port is already occupied, identify and reuse its supervisor. A foreground server started by an agent terminal tool is temporary: its timeout can kill it. Do not increase that timeout or repeatedly restart the gateway to repair dashboard startup.

`backend status` describes only the dedicated service managed by this command. Other supervisors may still provide a working backend. Custom HTTPS/IPv6 configurations require their existing supervisor. Unsupported service managers need an explicitly configured external supervisor.

To remove only the dedicated backend created by this command:

```sh
PYTHON -m hermes_jr.cli backend uninstall
```

## Companion bridge

After `setup`, install once:

```sh
PYTHON -m hermes_jr.cli service install
```

For an existing service:

```sh
PYTHON -m hermes_jr.cli service status
PYTHON -m hermes_jr.cli service start
PYTHON -m hermes_jr.cli service stop
PYTHON -m hermes_jr.cli service restart
PYTHON -m hermes_jr.cli service uninstall
```

Restart the companion after updating its Python package. If its Python environment moves, reinstall the service. Uninstalling startup leaves pairings and private state intact.

macOS needs a logged-in GUI session. Linux needs a systemd user manager; startup before login requires administrator-managed lingering. The commands do not configure lingering or root services.

## Diagnose once, repair the reported problem

```sh
PYTHON -m hermes_jr.cli doctor
PYTHON -m hermes_jr.cli service status
```

- **Installation missing/mismatch:** native plugin copies and the Python package must come from the same stable release. Follow [INSTALL.md](INSTALL.md).
- **Dashboard RPC failure:** inspect backend startup and its configured loopback port. A readable HTTP page is not enough.
- **Service failure:** inspect the private log path returned by `service status`. Fix the reported error before restarting.
- **Outdated pairing worker:** restart the companion service after updating.
- **Expired ticket:** keep the working installation and request a fresh prompt from Jr.
- **Pairing panel not active:** reopen the interactive Hermes CLI, or quit/reopen Hermes Desktop after a companion update. A terminal subprocess cannot load the plugin into its parent conversation. Use the same updated Hermes Python environment. Do not replace the panel with reasoning text, chat text, or a background watcher. Older Hermes builds without native question support need a Hermes update; existing phone connections continue working.

Dashboard credentials supplied through `HERMES_JR_DASHBOARD_TOKEN` or `HERMES_JR_DASHBOARD_SESSION_TOKEN` are saved privately by companion service installation. Stop and reinstall that service to update them. Normal loopback authentication does not need a manually supplied token.

Bridge logs rotate and omit credentials and conversation content. Health reports include a timestamp; stale health does not establish a current connection. Neither doctor nor service status sends a test notification.
