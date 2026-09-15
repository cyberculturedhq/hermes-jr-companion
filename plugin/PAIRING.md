# Manual pairing

For app-generated setup tickets, follow [INSTALL.md](INSTALL.md).

For manual QR pairing after installation:

```sh
PYTHON -m hermes_jr.cli pair --browser
```

Open the private page printed by the command and scan it in Jr. Keep the command running until it reports that the phone connected. The page then removes the code. Invitations expire after ten minutes; keep the page private because possession authorizes pairing.

The `--json` and `--url` outputs are for integrations that manage their own authorization and completion. See the CLI help and [protocol](https://github.com/cyberculturedhq/hermes-jr-companion/blob/main/Protocol/HPKE.md).
