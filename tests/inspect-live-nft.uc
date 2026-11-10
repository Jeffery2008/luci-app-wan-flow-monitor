'use strict';

// Live, read-only check: which routing rules does the collector attribute to
// the current connections? Run on the router with:
//   MISMATCH=1 ucode -S -L /usr/share/ucode tests/inspect-live-nft.uc

const collector = require('wan_flow_monitor.collector');

let snapshot = collector.snapshot();
let flows = collector.device_flows; // per-device API, used below for all devices
let counts = {};
let all = [];

for (let device in snapshot.devices)
	if (device.activeConnections)
		all = [ ...all, ...flows(device.key).flows ];

for (let flow in all) {
	let key = `${flow.ruleName || '(无规则)'} | 策略 ${flow.configuredPath} | 实际 ${flow.observedPath}`;
	counts[key] = (counts[key] || 0) + (flow.aggregatedFlowCount || 1);
}

for (let error in snapshot.errors || [])
	printf('error %s %s %s\n', error.source, error.code, error.message);

for (let key in sort(keys(counts)))
	printf('%4d  %s\n', counts[key], key);

if (getenv('MISMATCH'))
	for (let flow in all)
		if (flow.mismatch)
			printf('  %s %s %s:%d mark=0x%x nat=%s ev=%s conf=%s | %s\n',
				flow.device.name, flow.protocol, flow.destIp, flow.destPort,
				flow.firewallMark || 0, flow.natSource, flow.evidence, flow.confidence,
				flow.ruleReason);
