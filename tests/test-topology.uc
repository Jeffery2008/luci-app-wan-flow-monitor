'use strict';

// Discovery, policy and flow attribution against tests/fixtures/topology.json:
// a router with wan (+wan6) and lte, lan and guest, pbr and mwan3 together.
// None of these names exist in the code; everything must be discovered.

const fs = require('fs');
const discovery = require('wan_flow_monitor.discovery');
const policy = require('wan_flow_monitor.policy');
const flows = require('wan_flow_monitor.flows');

let fixture_root = getenv('FIXTURE_ROOT') || './tests/fixtures';
let fixture = json(fs.readfile(`${fixture_root}/topology.json`));
let failures = 0;

function check(condition, message) {
	if (condition) {
		print(`ok - ${message}\n`);
		return;
	}

	warn(`not ok - ${message}\n`);
	failures++;
}

function connection(protocol, src, sport, dst, dport, reply_dst, mark) {
	return {
		id: `${protocol}|${src}|${sport}|${dst}|${dport}`,
		family: index(src, ':') >= 0 ? 'ipv6' : 'ipv4',
		protocol,
		state: 'ESTABLISHED',
		mark: mark || 0,
		timeout: 100,
		original: { source: src, destination: dst, sourcePort: sport, destinationPort: dport, packets: 10, bytes: 1000 },
		reply: { source: dst, destination: reply_dst || src, sourcePort: dport, destinationPort: sport, packets: 10, bytes: 1000 },
		totalPackets: 20,
		totalBytes: 2000
	};
}

/* ---------- discovery ---------- */

let state = policy.load(fixture.config);
let topology = discovery.discover(fixture.dump, fixture.config, fixture.routes, state.referencedInterfaces);
let ids = map(topology.exits, (exit) => exit.id);

check(length(topology.exits) == 2, 'discovers two exits');
check(ids[0] == 'wan' && ids[1] == 'lte', 'orders the default-route exit first');
check(join(',', topology.exits[0].aliases) == 'wan,wan6', 'merges wan6 into wan (same L3 device)');
check(length(topology.exits[0].ipv6) == 1, 'keeps the wan6 address on the merged exit');
check(topology.defaultExit.ipv4 == 'wan' && topology.defaultExit.ipv6 == 'wan', 'default exit per family');
check(!topology.aliasMap.spare, 'ignores a down interface outside any WAN zone');
check(join(',', map(topology.segments, (s) => s.id)) == 'lan,guest', 'discovers lan and guest segments');
check(index(topology.segments[0].cidrs, '10.10.0.0/24') >= 0, 'segment carries its IPv4 subnet');
check(index(topology.segments[0].cidrs, '2001:db8:10::/64') >= 0, 'segment carries its IPv6 prefix');
check(discovery.segment_for_ip(topology, '10.20.0.7') == 'guest', 'maps an address to its segment');
check(topology.wanAddresses['100.80.1.2'] == 'lte', 'indexes WAN addresses');

/* ---------- policy ---------- */

policy.resolve(state, topology);
let prepared = policy.prepare(state, null);
let rule = (name) => filter(state.rules, (r) => r.name == name)[0];

check(length(state.providers) == 2, 'loads pbr and mwan3 together');
check(rule('Console via LTE').exits[0] == 'lte', 'maps a pbr interface name onto its exit');
check(rule('VPN that does not exist').missingInterfaces[0] == 'vpn', 'reports rules that reference a missing interface');
check(join('+', rule('https').exits) == 'wan+lte', 'mwan3 balanced policy keeps equal-metric members');
check(join('+', rule('default_rule').exits) == 'wan', 'mwan3 failover policy picks the lowest metric');

let console_flow = { connection: connection('udp', '10.10.0.30', 5000, '198.51.100.9', 3074), mac: 'AA:BB:CC:00:00:01', sourceIp: '10.10.0.30' };
check(policy.attribute(prepared, console_flow)?.rule?.name == 'Console via LTE', 'attributes a source-MAC rule');

let other_flow = { connection: connection('tcp', '10.10.0.31', 5001, '192.0.2.80', 443), mac: 'AA:BB:CC:00:00:09', sourceIp: '10.10.0.31' };
let matched = policy.attribute(prepared, other_flow);
check(matched?.rule?.name == 'https', 'skips the rule with a missing interface and falls through to mwan3');
check(policy.configured(matched, 'ipv4', topology).path == 'balanced', 'balanced rule is configured as balanced');

let local_flow = { connection: connection('tcp', '10.10.0.31', 5002, '10.20.0.7', 22), mac: 'AA:BB:CC:00:00:09', sourceIp: '10.10.0.31' };
check(policy.configured(policy.attribute(prepared, local_flow), 'ipv4', topology).path == 'local', 'ignore rule means local');

/* ---------- flows ---------- */

let devices = flows.build_devices(
	[ { mac: 'AA:BB:CC:00:00:01', ipv4: '10.10.0.30', hostname: 'console' } ],
	[ { ip: '10.10.0.20', mac: 'AA:BB:CC:00:00:02', device: 'br-lan', state: 'REACHABLE' } ],
	fixture.config.hosts, topology, policy.policy_macs(state)
);
let nas = filter(devices, (d) => d.mac == 'AA:BB:CC:00:00:02')[0];
check(nas?.hostname == 'nas' && nas?.segment == 'lan', 'names a neighbour from static DHCP hosts');

let ctx = flows.build_context({
	sampleAt: 1000, topology, devices, policy: prepared, routes: fixture.routes,
	ipRules: [], sockets: [], listeners: [
		{ protocol: 'udp', local: { address: '0.0.0.0', port: 6881 }, peer: { address: '0.0.0.0', port: 0 }, processName: 'transmission' }
	], previousCounters: {}
});

let via_lte = flows.build_flow(connection('udp', '10.10.0.30', 5000, '198.51.100.9', 3074, '100.80.1.2'), ctx);
check(via_lte.observedPath == 'lte' && via_lte.evidence == 'conntrack', 'NAT address proves the lte exit');
check(via_lte.configuredPath == 'lte' && !via_lte.mismatch, 'matches its policy');

let leaked = flows.build_flow(connection('udp', '10.10.0.30', 5003, '192.0.2.9', 3074, '203.0.113.10'), ctx);
check(leaked.observedPath == 'wan' && leaked.mismatch, 'flags a policy mismatch');

let app = flows.build_flow(connection('udp', '203.0.113.10', 6881, '192.0.2.50', 51413), ctx);
check(app.device.kind == 'app' && app.device.name == 'transmission', 'attributes router traffic to its process by port');
check(app.observedPath == 'wan', 'router traffic from a WAN address uses that exit');

let routed = flows.build_flow(connection('tcp', '10.10.0.20', 6000, '198.51.100.20', 80), ctx);
check(routed.observedPath == 'lte' && routed.evidence == 'route', 'falls back to the longest-prefix route');

if (failures)
	exit(1);

print('All topology fixture tests passed.\n');
