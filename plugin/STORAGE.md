# Companion storage limits

The companion reserves storage before a new upload or Bot Chat reply. SQLite serializes reply reservations. A private file lock serializes upload reservations, file writes, and partial-file cleanup across processes.

| Resource | Per device | Per computer |
| --- | --- | --- |
| Upload bytes, including reserved partial files | 1 GiB | 4 GiB |
| Upload files and directory allocations | 1,024 | 4,096 |
| Reply bytes, including saved payloads and record allowance | 16 MiB | 64 MiB |
| Reply records | 1,024 | 4,096 |

Each file includes a 4 KiB accounting allowance. Each reply includes its UTF-8 serialized size and a 512-byte allowance. New work also needs 256 MiB of free disk space. A supported batch of 20 attachments at 25 MiB each fits the default per-device limit.

A full limit returns HTTP 507. The app keeps the unsent message. A retry of the same reserved upload or reply can continue at the limit. Changing the payload of a reply ID remains an error.

Cleanup removes only incomplete uploads that have been idle for 24 hours or belong to a revoked device. It keeps completed attachments and reply records. History, queued work, and an uncertain delivery result can still need these records. Do not delete them merely to meet a time limit.

The first process after startup includes existing files in its accounting. This also covers files written by an older version after rollback. Existing files stay in place. If they already exceed a limit, new allocation stops. Older running versions do not enforce these limits. Restart loaded Hermes processes after applying the security update.

An operator can set positive integer limits in the private companion `storage_limits` setting. The setting uses these keys: `upload_device_bytes`, `upload_host_bytes`, `upload_device_count`, `upload_host_count`, `reply_device_bytes`, `reply_host_bytes`, `reply_device_count`, `reply_host_count`, and `free_disk_bytes`. Check disk capacity and retained history before raising a limit. Free disk space alone does not remove a retained record from quota accounting.
