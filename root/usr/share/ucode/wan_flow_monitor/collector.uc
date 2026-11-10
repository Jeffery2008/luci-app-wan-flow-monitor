'use strict';

/*
 * Read-only collector. Gathers live state from a fixed set of sources,
 * caches each source with its own TTL and assembles one snapshot:
 *
 *   discovery.uc  WAN exits / LAN segments from netifd + firewall + DHCP
 *   policy.uc     pbr / mwan3 rules mapped onto those exits
 *   flows.uc      conntrack -> flows, devices and statistics
 *
 * On failure the last good snapshot is returned with structured errors.
 */

const fs = require('fs');
const uci_module = require('uci');
const ubus_module = require('ubus');
const parsers = require('wan_flow_monitor.parsers');
const util = require('wan_flow_monitor.util');
const discovery = require('wan_flow_monitor.discovery');
const policy = require('wan_flow_monitor.policy');
const flows_module = require('wan_flow_monitor.flows');

/*
 * This is the complete command allowlist. No RPC argument is ever interpolated
 * into a command. UCI, ubus, /proc and /sys data are read through native APIs.
 */
const COMMANDS = {
	routes4: '/sbin/ip -j route show table all',
	routes6: '/sbin/ip -j -6 route show table all',
	rules4: '/sbin/ip -j rule',
	rules6: '/sbin/ip -j -6 rule',
	neighbours4: '/sbin/ip -j neigh',
	neighbours6: '/sbin/ip -j -6 neigh',
	nft: '/usr/sbin/nft -j list table inet fw4',
	conntrack: '/usr/sbin/conntrack -L -o extended',
	sockets: '/usr/sbin/ss -H -ntup',
	listeners: '/usr/sbin/ss -H -lntup'
};

const TTL = {
	network: 3,
	config: 30,
	routes4: 5,
	routes6: 5,
	rules4: 10,
	rules6: 10,
	neighbours4: 5,
	neighbours6: 5,
	nft: 15,
	conntrack: 3,
	sockets: 3,
	listeners: 10,
	leases: 15
};

const HISTORY_SECONDS = 300;
const STALE_SECONDS = 15;
const OVERVIEW_FLOWS = 150;
const SCHEMA_VERSION = 2;

let STATE = {
	sources: {},
	previousCounters: {},
	interfaceStats: {},
	lastConntrackAt: 0,
	latest: null,
	flows: [],
	history: []
};

/* ---------- cached sources ---------- */

function fresh(entry, ttl) {
	return entry?.updatedAt && util.now() - entry.updatedAt < ttl;
}

function source_ok(name, value) {
	STATE.sources[name] = {
		value,
		updatedAt: util.now(),
		lastAttemptAt: util.now(),
		error: null
	};

	return STATE.sources[name];
}

function source_failure(name, code, message) {
	let previous = STATE.sources[name];
	let error = util.structured_error(name, code, message, !!previous?.value);

	if (previous) {
		previous.lastAttemptAt = util.now();
		previous.error = error;
		return previous;
	}

	STATE.sources[name] = { value: null, updatedAt: 0, lastAttemptAt: util.now(), error };
	return STATE.sources[name];
}

function command_source(name, parser) {
	let cached = STATE.sources[name];

	if (fresh(cached, TTL[name]))
		return cached;

	let command = COMMANDS[name];

	if (!command)
		return source_failure(name, 'not_allowlisted', '数据源不在固定命令白名单中');

	let handle = fs.popen(command, 'r');

	if (!handle)
		return source_failure(name, 'command_start_failed', '无法启动只读采集命令');

	let output = handle.read('all');
	let status = handle.close();

	if (output == null)
		return source_failure(name, 'command_read_failed', '无法读取采集命令输出');

	if (status != 0)
		return source_failure(name, 'command_failed', `只读采集命令退出码 ${status}`);

	try {
		return source_ok(name, parser(output));
	}
	catch (error) {
		return source_failure(name, 'parse_failed', `${error}`);
	}
}

function leases_source() {
	let cached = STATE.sources.leases;

	if (fresh(cached, TTL.leases))
		return cached;

	let content = fs.readfile('/tmp/dhcp.leases');

	try {
		return source_ok('leases', content == null ? [] : parsers.parse_dhcp_leases(content, util.now()));
	}
	catch (error) {
		return source_failure('leases', 'parse_failed', `${error}`);
	}
}

function network_source() {
	let cached = STATE.sources.network;

	if (fresh(cached, TTL.network))
		return cached;

	let ubus = ubus_module.connect();

	if (!ubus)
		return source_failure('network', 'ubus_unavailable', '无法连接 ubus');

	try {
		let dump = ubus.call('network.interface', 'dump', {});

		if (!dump)
			return source_failure('network', 'ubus_call_failed', 'network.interface dump 无返回');

		return source_ok('network', dump);
	}
	catch (error) {
		return source_failure('network', 'ubus_call_failed', `${error}`);
	}
}

/* Copy only the routing-related options of a UCI section. */
function pick(section, fields) {
	let result = { '.name': section['.name'] };

	for (let field in fields)
		if (section[field] != null)
			result[field] = section[field];

	return result;
}

function sections(cursor, config, type, fields) {
	let result = [];

	cursor.foreach(config, type, (section) => {
		push(result, pick(section, fields));
	});

	return result;
}

function config_source() {
	let cached = STATE.sources.config;

	if (fresh(cached, TTL.config))
		return cached;

	try {
		let cursor = uci_module.cursor();
		let value = {
			zones: map(sections(cursor, 'firewall', 'zone', [ 'name', 'network', 'masq', 'masq6' ]), (zone) => ({
				name: util.safe_text(zone.name, zone['.name']),
				networks: util.as_list(zone.network),
				masq: zone.masq,
				masq6: zone.masq6
			})),
			dhcp: sections(cursor, 'dhcp', 'dhcp', [ 'interface', 'ignore' ]),
			hosts: map(sections(cursor, 'dhcp', 'host', [ 'name', 'mac', 'ip' ]), (host) => ({
				name: util.safe_text(host.name, null),
				mac: util.as_list(host.mac),
				ip: util.safe_text(host.ip, null)
			})),
			pbr: null,
			mwan3: null
		};

		if (cursor.get('pbr', 'config') != null || length(sections(cursor, 'pbr', 'policy', [])))
			value.pbr = {
				enabled: cursor.get('pbr', 'config', 'enabled'),
				policies: sections(cursor, 'pbr', 'policy', [
					'name', 'enabled', 'interface', 'proto', 'chain',
					'src_addr', 'src_port', 'dest_addr', 'dest_port'
				])
			};

		let mwan3_interfaces = sections(cursor, 'mwan3', 'interface', [ 'enabled', 'family' ]);

		if (length(mwan3_interfaces))
			value.mwan3 = {
				enabled: true,
				interfaces: mwan3_interfaces,
				members: sections(cursor, 'mwan3', 'member', [ 'interface', 'metric', 'weight' ]),
				policies: sections(cursor, 'mwan3', 'policy', [ 'use_member', 'last_resort' ]),
				rules: sections(cursor, 'mwan3', 'rule', [
					'src_ip', 'src_port', 'dest_ip', 'dest_port', 'proto',
					'family', 'use_policy', 'ipset', 'sticky'
				])
			};

		return source_ok('config', value);
	}
	catch (error) {
		return source_failure('config', 'uci_read_failed', `${error}`);
	}
}

/* ---------- exits ---------- */

function interface_statistics(device) {
	device = util.safe_device_name(device);

	if (!device)
		return null;

	let root = `/sys/class/net/${device}/statistics`;

	return {
		rxBytes: util.read_number(`${root}/rx_bytes`),
		txBytes: util.read_number(`${root}/tx_bytes`),
		rxPackets: util.read_number(`${root}/rx_packets`),
		txPackets: util.read_number(`${root}/tx_packets`)
	};
}

/* Byte counters -> bytes/s, measured between network refreshes. */
function attach_rates(exits) {
	let measured_at = STATE.sources.network?.updatedAt || util.now();

	for (let exit in exits) {
		let stats = interface_statistics(exit.device);
		let previous = STATE.interfaceStats[exit.id];

		exit.statistics = stats;
		exit.rates = previous?.rates || null;

		if (!stats || stats.rxBytes == null)
			continue;

		if (!previous || measured_at > previous.at) {
			let elapsed = previous ? measured_at - previous.at : 0;
			let rates = elapsed > 0 ? {
				rx: max(0, (stats.rxBytes - previous.rx) / elapsed),
				tx: max(0, (stats.txBytes - previous.tx) / elapsed)
			} : previous?.rates;

			STATE.interfaceStats[exit.id] = { at: measured_at, rx: stats.rxBytes, tx: stats.txBytes, rates };
			exit.rates = rates || null;
		}
	}

	return exits;
}

/* ---------- snapshot ---------- */

function source_statuses() {
	let statuses = {};

	for (let name in keys(TTL))
		statuses[name] = util.source_status(STATE.sources[name], TTL[name]);

	return statuses;
}

function policy_summary(policy_state, prepared) {
	return {
		providers: map(policy_state.providers, (provider) => ({
			...provider,
			loaded: provider.id == 'pbr' ? prepared.pbrLoaded : provider.enabled
		})),
		rules: map(policy_state.rules, (rule) => ({
			id: rule.id,
			provider: rule.provider,
			name: rule.name,
			enabled: rule.enabled,
			target: rule.target,
			exits: rule.exits,
			missingInterfaces: rule.missingInterfaces
		}))
	};
}

function collect() {
	let network = network_source();
	let config = config_source();
	let parse_json = parsers.parse_json;
	let routes4 = command_source('routes4', (text) => parsers.parse_routes(parse_json(text), 'ipv4'));
	let routes6 = command_source('routes6', (text) => parsers.parse_routes(parse_json(text), 'ipv6'));
	let rules4 = command_source('rules4', (text) => parsers.parse_ip_rules(parse_json(text), 'ipv4'));
	let rules6 = command_source('rules6', (text) => parsers.parse_ip_rules(parse_json(text), 'ipv6'));
	let neighbours4 = command_source('neighbours4', (text) => parsers.parse_neighbours(parse_json(text)));
	let neighbours6 = command_source('neighbours6', (text) => parsers.parse_neighbours(parse_json(text)));
	let nft = command_source('nft', (text) => parsers.parse_nft(parse_json(text)));
	let conntrack = command_source('conntrack', parsers.parse_conntrack);
	let sockets = command_source('sockets', parsers.parse_ss);
	let listeners = command_source('listeners', parsers.parse_ss);
	let leases = leases_source();

	let routes = [ ...(routes4.value || []), ...(routes6.value || []) ];
	let ip_rules = [ ...(rules4.value || []), ...(rules6.value || []) ];
	let neighbours = [ ...(neighbours4.value || []), ...(neighbours6.value || []) ];

	let policy_state = policy.load(config.value || {});
	let topology = discovery.discover(network.value, config.value, routes, policy_state.referencedInterfaces);
	policy.resolve(policy_state, topology);
	let prepared = policy.prepare(policy_state, nft.value);

	let devices = flows_module.build_devices(
		leases.value || [],
		neighbours,
		config.value?.hosts || [],
		topology,
		policy.policy_macs(policy_state)
	);
	let context = flows_module.build_context({
		sampleAt: conntrack.updatedAt || util.now(),
		topology,
		devices,
		policy: prepared,
		routes,
		ipRules: ip_rules,
		sockets: sockets.value,
		listeners: listeners.value,
		previousCounters: STATE.previousCounters
	});
	let new_sample = context.sampleAt != STATE.lastConntrackAt;
	let flows = STATE.flows;

	if (new_sample) {
		/* Link-scoped traffic (DHCP discovery, mDNS, fe80::) never reaches a WAN. */
		let routable = filter(conntrack.value || [], (connection) =>
			!util.is_link_scoped(connection.original.source) &&
			!util.is_link_scoped(connection.original.destination)
		);

		flows = flows_module.aggregate(map(routable, (connection) =>
			flows_module.build_flow(connection, context)
		));

		STATE.previousCounters = context.nextCounters;
		STATE.lastConntrackAt = context.sampleAt;
		STATE.flows = flows;

		push(STATE.history, { timestamp: context.sampleAt, links: flows_module.compact_links(flows) });

		while (length(STATE.history) && STATE.history[0].timestamp < context.sampleAt - HISTORY_SECONDS)
			shift(STATE.history);
	}

	flows_module.apply_stats(devices, flows, context, prepared, STATE.history);

	let statuses = source_statuses();
	let errors = [];

	for (let name in keys(statuses))
		if (statuses[name].error)
			push(errors, statuses[name].error);

	let data_timestamp = conntrack.updatedAt || 0;

	STATE.latest = {
		schemaVersion: SCHEMA_VERSION,
		generatedAt: util.now(),
		dataTimestamp: data_timestamp,
		stale: !data_timestamp || util.now() - data_timestamp > STALE_SECONDS,
		readOnly: true,
		productionData: true,
		dataSource: 'router',
		exits: attach_rates(topology.exits),
		defaultExit: topology.defaultExit,
		segments: flows_module.segment_stats(topology.segments, devices),
		policy: policy_summary(policy_state, prepared),
		devices,
		flows: flows_module.active(flows, OVERVIEW_FLOWS),
		flowCount: length(flows),
		sourceStatus: statuses,
		errors,
		history: {
			oldestTimestamp: STATE.history[0]?.timestamp || null,
			newestTimestamp: STATE.history[length(STATE.history) - 1]?.timestamp || null,
			sampleCount: length(STATE.history),
			retentionSeconds: HISTORY_SECONDS
		}
	};

	return STATE.latest;
}

function empty_snapshot(error) {
	return {
		schemaVersion: SCHEMA_VERSION,
		generatedAt: util.now(),
		dataTimestamp: 0,
		stale: true,
		readOnly: true,
		productionData: true,
		dataSource: 'router',
		exits: [],
		defaultExit: { ipv4: null, ipv6: null },
		segments: [],
		policy: { providers: [], rules: [] },
		devices: [],
		flows: [],
		flowCount: 0,
		sourceStatus: {},
		errors: [ error ],
		history: { oldestTimestamp: null, newestTimestamp: null, sampleCount: 0, retentionSeconds: HISTORY_SECONDS }
	};
}

function snapshot() {
	try {
		return collect();
	}
	catch (error) {
		let structured = util.structured_error('collector', 'collector_failed', `${error}`, !!STATE.latest);

		if (!STATE.latest)
			return empty_snapshot(structured);

		return {
			...STATE.latest,
			generatedAt: util.now(),
			stale: true,
			errors: [ ...(STATE.latest.errors || []), structured ]
		};
	}
}

function history(since, limit) {
	since = max(util.now() - HISTORY_SECONDS, int(since || 0));
	limit = util.clamp(limit || 120, 1, 120);

	let samples = filter(STATE.history, (sample) => sample.timestamp >= since);

	if (length(samples) > limit)
		samples = slice(samples, length(samples) - limit);

	return {
		generatedAt: util.now(),
		dataTimestamp: STATE.latest?.dataTimestamp || 0,
		retentionSeconds: HISTORY_SECONDS,
		samples
	};
}

/* All current connections of one device; key is compared, never executed. */
function device_flows(key) {
	key = `${key ?? ''}`;

	let matching = filter(STATE.flows || [], (flow) => flow.device.key == key);

	sort(matching, (a, b) => (b.bytesPerSecond - a.bytesPerSecond) || (b.totalBytes - a.totalBytes));

	return {
		generatedAt: util.now(),
		dataTimestamp: STATE.latest?.dataTimestamp || 0,
		device: key,
		total: length(matching),
		flows: slice(matching, 0, 100)
	};
}

function health() {
	let timestamp = STATE.latest?.dataTimestamp || 0;

	return {
		ok: !!STATE.latest,
		readOnly: true,
		generatedAt: util.now(),
		lastDataTimestamp: timestamp,
		stale: !timestamp || util.now() - timestamp > STALE_SECONDS,
		errorCount: length(STATE.latest?.errors || [])
	};
}

return {
	snapshot,
	history,
	device_flows,
	health,
	commandAllowlist: keys(COMMANDS)
};
