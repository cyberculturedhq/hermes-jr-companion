"""Fast, fail-open lifecycle observers. Network delivery belongs to the bridge."""
from __future__ import annotations
import logging
from pathlib import Path
from .state import State

log = logging.getLogger("hermes_jr")


def register(ctx):
    manifest_path = getattr(getattr(ctx, 'manifest', None), 'path', None)
    def record(kind, session_id, key):
        # A native uninstall may happen while this Python conversation remains alive.
        # Do not resurrect the state directory from callbacks loaded before removal.
        if not Path(__file__).is_file() or (manifest_path and not Path(manifest_path).exists()):
            return
        if not session_id or not key:
            return
        try:
            aliases = []
            session_title = ""
            # Public SessionDB surface handles compression-created continuation sessions.
            try:
                from hermes_state import SessionDB
                db = SessionDB()
                try:
                    aliases = db.get_compression_lineage(session_id)
                    session_title = (db.get_session(session_id) or {}).get("title") or ""
                finally:
                    db.close()
            except Exception:
                pass  # Exact durable session identity remains safe when lineage is unavailable.
            State().enqueue(ctx.profile_name, session_id, kind, f"{ctx.profile_name}:{session_id}:{kind}:{key}", aliases, session_title=session_title)
        except Exception:
            # Avoid exception strings, hook kwargs, prompts, or tokens in logs.
            log.warning("Hermes Jr. could not queue a notification")

    def completed(session_id="", completed=False, failed=False, interrupted=False, turn_id="", task_id="", **kwargs):
        if interrupted or not (completed or failed):
            return
        record("error" if failed else "completed", session_id, turn_id or task_id)

    def approval(session_id="", session_key="", turn_id="", tool_call_id="", request_id="", surface="", **kwargs):
        if surface == "smart":
            return
        record("approval", session_id or session_key, request_id or tool_call_id or turn_id)

    def tool(tool_name="", session_id="", tool_call_id="", **kwargs):
        if tool_name == "clarify":
            record("clarification", session_id, tool_call_id)
        return None

    ctx.register_hook("on_session_end", completed)
    ctx.register_hook("pre_approval_request", approval)
    ctx.register_hook("pre_tool_call", tool)
    from .cli import configure_parser, dispatch
    ctx.register_cli_command("jr", "Hermes Jr. companion", configure_parser, dispatch)
    from .pairing_panel import register as register_pairing_panel
    register_pairing_panel(ctx)
