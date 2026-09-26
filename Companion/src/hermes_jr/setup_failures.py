"""Sanitized setup outcomes; never persist raw exception text or credentials."""
FAILURES = {
    'expired': ('The time to connect or compare the codes ran out.', 'Ask for a fresh setup prompt; reuse the installed companion.'),
    'cancelled': ('This setup was canceled or another host was selected.', 'Ask whether the user wants to start a new setup; reuse the companion.'),
    'unavailable': ('The service no longer has this setup attempt.', 'Ask for a fresh setup prompt; reuse the companion.'),
    'rejected': ('The service did not accept this setup request.', 'Check the companion service registration with doctor before starting another attempt.'),
    'conflict': ('This setup conflicts with the service’s current pairing state.', 'Check the current attempt on the phone before starting another one.'),
    'verification': ('The connection could not be verified.', 'Do not confirm the codes. Cancel the attempt and start again with the intended Hermes host.'),
    'internal': ('The companion encountered an unexpected setup error.', 'Check companion diagnostics before retrying. A new ticket or reinstall alone may not resolve it.'),
}


class SetupFailure(ValueError):
    def __init__(self, reason):
        if reason not in FAILURES:
            reason = 'internal'
        self.reason = reason
        super().__init__(FAILURES[reason][0])


def details(reason):
    reason = reason if reason in FAILURES else 'internal'
    message, recovery = FAILURES[reason]
    return {'reason': reason, 'message': message, 'recovery': recovery}
