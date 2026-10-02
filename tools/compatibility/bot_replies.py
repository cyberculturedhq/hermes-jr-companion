"""Check replies against Hermes' real database, writer registry and mailbox.

Use temporary state only. Do not construct an agent or call a model.
"""
from pathlib import Path
import tempfile
from unittest.mock import patch
import uuid

from hermes_jr import bot_replies as replies
from hermes_jr.state import State


def check():
    if not replies.supported():
        assert replies.supported() == 0
        print('PASS: older Hermes reports bot replies unavailable')
        return
    from hermes_state import SessionDB
    from hermes_cli.active_sessions import try_acquire_active_session, transfer_active_session
    from tools import bot_live_delivery as mailbox
    with tempfile.TemporaryDirectory(prefix='jr-bot-replies-') as directory:
        home = Path(directory) / 'profile'
        home.mkdir()
        state = State(Path(directory) / 'companion')
        device = str(uuid.uuid4())
        db = SessionDB(db_path=home / 'state.db')
        db.create_session(session_id='bot-root', source='cli')
        db.set_session_title('bot-root', 'Bot Chat')
        metadata = dict(live_session_id='desktop-owner', bot_live_delivery_consumer=True)
        lease, refusal = try_acquire_active_session(session_id='bot-root', surface='desktop',
            config={}, registry_home=home, metadata=metadata)
        assert refusal is None and lease is not None
        body = dict(profile='research', session_id='bot-root', text='Testing', attachments=[])
        request = str(uuid.uuid4())
        try:
            with patch.object(replies, 'runtime', return_value=(home, SessionDB, mailbox)):
                assert replies.submit(state, device, request, 'research', 'bot-root', body)['status'] == 'queued'
                # A process restart or lost acknowledgement keeps the same durable delivery.
                assert replies.submit(State(state.directory), device, request, 'research', 'bot-root', body)['status'] == 'queued'
                owner = mailbox.find_canonical_live_owner(home)
                receipt = mailbox.claim_pending_delivery(home, owner)
                assert receipt['message'] == 'Testing' and receipt.get('author') is None
                assert mailbox.claim_pending_delivery(home, owner) is None
                assert replies.result(state, device, request)['status'] == 'claimed'
                assert replies.result(state, device, request, cancel=True)['status'] == 'claimed'
                mailbox.complete_delivery(home, receipt['delivery_id'], status='settled', reply='Bot reply')
                result = replies.result(state, device, request)
                assert result['status'] == 'settled' and result['reply'] == 'Bot reply'
                assert replies.submit(state, device, request, 'research', 'bot-root', body) == result

                # Compression changes storage identity without changing the conversation or writer.
                request = str(uuid.uuid4())
                assert replies.submit(state, device, request, 'research', 'bot-root', body)['status'] == 'queued'
                db.end_session('bot-root', 'compression')
                db.create_session(session_id='bot-tip', source='cli', parent_session_id='bot-root')
                assert transfer_active_session(lease, session_id='bot-tip', metadata=metadata)
                owner = mailbox.find_canonical_live_owner(home)
                receipt = mailbox.claim_pending_delivery(home, owner)
                assert receipt['message'] == 'Testing'
                mailbox.complete_delivery(home, receipt['delivery_id'], status='settled', reply='Compressed reply')
                result = replies.result(state, device, request)
                assert result['session_id'] == 'bot-tip' and result['reply'] == 'Compressed reply'

                # An owner that closes before admission to a turn cannot receive a replay elsewhere.
                request = str(uuid.uuid4())
                assert replies.submit(state, device, request, 'research', 'bot-root', body)['status'] == 'queued'
                lease.release()
                assert replies.result(state, device, request)['status'] == 'cancelled'
                assert replies.submit(state, device, request, 'research', 'bot-root', body)['status'] == 'cancelled'
                unowned = replies.submit(state, device, str(uuid.uuid4()), 'research', 'bot-root', body)
                assert unowned['route'] == 'session' and unowned['session_id'] == 'bot-tip'
        finally:
            lease.release()
            db.close()
    print('PASS: real Hermes bot replies preserve human attribution, one writer, receipts and compression')


if __name__ == '__main__':
    check()
