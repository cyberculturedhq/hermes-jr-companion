"""Expire unapproved invitations locally, then retry idempotent service deletion."""
import asyncio
import aiohttp


async def sweep(state, service):
    state.expire_pending()
    for pending in state.pending_deletions():
        try:
            await service.delete_device(pending['device_id'])
        except (aiohttp.ClientError, ValueError, TimeoutError):
            state.retry_deletion(pending['device_id'], pending['attempts'])
        else:
            state.deleted_remotely(pending['device_id'])


async def watch(state, service):
    while True:
        await sweep(state, service)
        await asyncio.sleep(30)
