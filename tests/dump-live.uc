'use strict';

// Read-only: print one JSON document with the same payloads the RPC methods
// return, for the local page preview (tests/harness). Run on the router:
//   ucode -S -L /usr/share/ucode tests/dump-live.uc > /tmp/wfm-dump.json

const collector = require('wan_flow_monitor.collector');
const fs = require('fs');

collector.snapshot();

for (let i = 0; i < 2; i++) {
	fs.popen('/bin/sleep 4', 'r')?.close();
	collector.snapshot();
}

let overview = collector.snapshot();
let flows = {};

for (let device in overview.devices)
	if (device.activeConnections)
		flows[device.key] = collector.device_flows(device.key);

printf('%J\n', { overview, history: collector.history(0, 120), flows });
