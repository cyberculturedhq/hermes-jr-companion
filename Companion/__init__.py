"""Hermes' native plugin entry point. Registration never opens network connections."""
def register(ctx):
    from hermes_jr.plugin import register as register_companion
    register_companion(ctx)
