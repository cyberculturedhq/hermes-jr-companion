# Status and remaining work

Hermes Jr. uses phone-bound tickets and numeric comparison for setup. The companion provides encrypted relay and notifications, managed startup, explicit signed updates with code rollback, and expired setup cleanup.

Remaining work:

- Publish the iOS source and independent build instructions under the same organization.
- Configure production APNs before TestFlight/App Store distribution; the hosted service currently supports development builds.
- Detect new profiles and offer companion activation with a remembered “Not now” choice. The installer covers existing profiles only.
- Independent encryption/pairing review and compatibility tests between released app/companion versions.
- Real Linux service, reboot, offline, and prolonged-workload validation beyond CI.

See the dated validation records for what was actually tested. Automated checks do not establish production readiness or an independent security review.
