'use strict';

// Live, read-only smoke check on a router:
//   SECOND_SAMPLE=1 ucode -S -L /usr/share/ucode tests/smoke-live.uc
// Prints what was discovered and how flows are attributed. Changes nothing.

const collector = require('wan_flow_monitor.collector');

function wait(seconds) {
	let handle = require('fs').popen(`/bin/sleep ${int(seconds)}`, 'r');
	handle?.close();
}

let snapshot = collector.snapshot();

if (getenv('SECOND_SAMPLE')) {
	wait(4);
	snapshot = collector.snapshot();
}

printf('schema=%d stale=%s exits=%d segments=%d devices=%d flows=%d/%d errors=%d\n',
	snapshot.schemaVersion, snapshot.stale, length(snapshot.exits), length(snapshot.segments),
	length(snapshot.devices), length(snapshot.flows), snapshot.flowCount, length(snapshot.errors));

for (let exit in snapshot.exits)
	printf('exit %-10s aliases=%J dev=%s zone=%s up=%s default4=%s default6=%s v4=%J health=%s rates=%J\n',
		exit.id, exit.aliases, exit.device, exit.zone, exit.up, exit.isDefault4, exit.isDefault6,
		map(exit.ipv4, (a) => a.address), exit.health.status, exit.rates);

printf('defaultExit=%J\n', snapshot.defaultExit);

for (let segment in snapshot.segments)
	printf('segment %-10s kind=%s dev=%s cidrs=%J devices=%d active=%d traffic=%J\n',
		segment.id, segment.kind, segment.device, segment.cidrs, segment.deviceCount,
		segment.activeDevices, segment.traffic);

for (let provider in snapshot.policy.providers)
	printf('provider %s enabled=%s loaded=%s rules=%d\n',
		provider.id, provider.enabled, provider.loaded, provider.ruleCount);

for (let rule in snapshot.policy.rules)
	printf('  rule %-45s target=%s exits=%J missing=%J\n',
		rule.name, rule.target, rule.exits, rule.missingInterfaces);

for (let device in slice(filter(snapshot.devices, (d) => d.activeConnections > 0), 0, 12))
	printf('device %-28s kind=%-6s seg=%-8s conf=%-8s obs=%-8s conns=%d mismatch=%d bps=%d\n',
		device.name, device.kind, device.segment, device.configured?.path, device.observedPath,
		device.activeConnections, device.mismatchConnections, device.bytesPerSecond);

for (let error in snapshot.errors)
	printf('error %s %s %s\n', error.source, error.code, error.message);
