'use strict';

/*
 * Turn conntrack entries into flows: who (device / router process / host),
 * where it actually leaves (observed exit + evidence), and what the policy
 * says (configured exit + rule). Also builds the device list and per-device,
 * per-segment statistics. No interface names or ports are hardcoded.
 */

const util = require('wan_flow_monitor.util');
const discovery = require('wan_flow_monitor.discovery');
const policy = require('wan_flow_monitor.policy');

const MAX_FLOWS = 300;
const DETAILED_FLOWS = 250;

/* ---------- devices ---------- */

function new_device(mac) {
	return {
		key: mac,
		kind: 'device',
		mac,
		hostname: null,
		ipv4: null,
		ipv6: [],
		segment: null,
		online: false,
		leaseExpiresAt: null
	};
}

function device_for(by_mac, mac) {
	if (!by_mac[mac])
		by_mac[mac] = new_device(mac);

	return by_mac[mac];
}

/*
 * leases:     parsed /tmp/dhcp.leases
 * neighbours: parsed `ip -j neigh` (v4 + v6)
 * hosts:      static DHCP hosts [{ name, mac: [..], ip }] (names only)
 * macs:       MACs referenced by routing policies (kept even when offline)
 */
function build_devices(leases, neighbours, hosts, topology, macs) {
	let by_mac = {};
	let names = {};

	for (let host in hosts || [])
		for (let mac in host.mac || [])
			if (util.is_mac(mac))
				names[uc(mac)] = { name: host.name, ip: host.ip };

	for (let lease in leases || []) {
		let device = device_for(by_mac, uc(lease.mac));

		device.hostname = lease.hostname || device.hostname;
		device.ipv4 = lease.ipv4 || device.ipv4;
		device.leaseExpiresAt = lease.expiresAt;
		device.segment = discovery.segment_for_ip(topology, lease.ipv4);
	}

	for (let neighbour in neighbours || []) {
		if (!neighbour.mac || !util.is_mac(neighbour.mac))
			continue;

		/* Only neighbours on LAN segments are client devices. */
		let segment = topology.segmentByDevice[neighbour.device] ||
			discovery.segment_for_ip(topology, neighbour.ip);

		if (!segment)
			continue;

		let device = device_for(by_mac, uc(neighbour.mac));

		device.segment ||= segment;

		if (neighbour.state != 'FAILED' && neighbour.state != 'INCOMPLETE')
			device.online = true;

		if (util.is_ipv6(neighbour.ip)) {
			if (substr(neighbour.ip, 0, 4) != 'fe80')
				util.unique_push(device.ipv6, neighbour.ip);
		}
		else if (!device.ipv4) {
			device.ipv4 = neighbour.ip;
		}
	}

	for (let mac in keys(names)) {
		let device = by_mac[mac];

		if (!device)
			continue;

		device.hostname ||= util.safe_text(names[mac].name, null) || null;
		device.ipv4 ||= names[mac].ip || null;
		device.segment ||= discovery.segment_for_ip(topology, device.ipv4);
	}

	for (let mac in macs || [])
		device_for(by_mac, mac);

	return values(by_mac);
}

function index_devices(devices) {
	let by_ip = {};

	for (let device in devices) {
		if (device.ipv4)
			by_ip[device.ipv4] = device;

		for (let ip in device.ipv6)
			by_ip[ip] = device;
	}

	return by_ip;
}

/* ---------- router processes ---------- */

function socket_index(sockets, listeners) {
	let connected = {};
	let bound = {};

	for (let socket in sockets || [])
		if (socket.processName && socket.local && socket.peer)
			connected[`${socket.protocol}|${socket.local.port}|${socket.peer.address}|${socket.peer.port}`] =
				socket.processName;

	for (let socket in listeners || [])
		if (socket.processName && socket.local?.port)
			bound[`${socket.protocol}|${socket.local.port}`] ||= socket.processName;

	return { connected, bound };
}

function process_for(index_, protocol, local_port, remote_ip, remote_port) {
	return index_.connected[`${protocol}|${local_port}|${remote_ip}|${remote_port}`] ||
		index_.bound[`${protocol}|${local_port}`] || null;
}

/* ---------- who ---------- */

function identify(connection, ctx) {
	let original = connection.original;
	let reply = connection.reply;
	let device = ctx.devicesByIp[original.source];

	if (device)
		return { kind: 'device', device, direction: 'outbound', ip: original.source };

	device = ctx.devicesByIp[reply.source];

	if (device)
		return { kind: 'device', device, direction: 'inbound', ip: reply.source };

	let router = ctx.routerAddresses;

	if (router[original.source] || router[original.destination]) {
		let inbound = !router[original.source];
		let app = inbound
			? process_for(ctx.sockets, connection.protocol, original.destinationPort, original.source, original.sourcePort)
			: process_for(ctx.sockets, connection.protocol, original.sourcePort, original.destination, original.destinationPort);

		return {
			kind: app ? 'app' : 'router',
			app,
			direction: inbound ? 'inbound' : 'outbound',
			ip: inbound ? original.destination : original.source
		};
	}

	/* Forwarded traffic of hosts that are not DHCP/neighbour clients (containers, VPN peers). */
	let inbound = !!ctx.topology.wanAddresses[original.destination];
	let host = inbound ? reply.source : original.source;

	return { kind: 'host', direction: inbound ? 'inbound' : 'outbound', ip: host };
}

function endpoint_of(ident, topology) {
	switch (ident.kind) {
	case 'device':
		return {
			key: ident.device.key,
			kind: 'device',
			name: ident.device.hostname || ident.device.ipv4 || ident.device.mac,
			mac: ident.device.mac,
			ip: ident.ip,
			segment: ident.device.segment || 'other'
		};

	case 'app':
		return { key: `app:${ident.app}`, kind: 'app', name: ident.app, mac: null, ip: ident.ip, segment: 'router' };

	case 'router':
		return { key: 'router', kind: 'router', name: '路由器', mac: null, ip: ident.ip, segment: 'router' };

	default:
		return {
			key: `ip:${ident.ip}`,
			kind: 'host',
			name: ident.ip,
			mac: null,
			ip: ident.ip,
			segment: discovery.segment_for_ip(topology, ident.ip) || 'other'
		};
	}
}

/* ---------- where ---------- */

function route_device(routes, address) {
	let best = null;
	let best_length = -1;

	for (let route in routes) {
		if (route.prefix <= best_length || !util.ip_in_cidr(address, route.cidr))
			continue;

		best = route;
		best_length = route.prefix;
	}

	return best;
}

function exit_for_mark(mark, family, ctx) {
	if (!mark)
		return null;

	for (let rule in ctx.ipRules) {
		if (rule.family != family || rule.fwmark == null)
			continue;

		let mask = rule.fwmask == null ? 0xffffffff : rule.fwmask;

		if ((mark & mask) != (rule.fwmark & mask))
			continue;

		let route = util.find(ctx.tableDefaults, (candidate) =>
			candidate.family == family && candidate.table == `${rule.table}`
		);

		if (!route)
			continue;

		return {
			path: ctx.topology.deviceMap[route.device] || 'local',
			table: rule.table
		};
	}

	return null;
}

/*
 * Order of evidence, strongest first:
 *   NAT/WAN address in conntrack -> local destination -> fwmark -> route table.
 */
function observe(connection, ident, ctx) {
	let wan = ctx.topology.wanAddresses;
	let original = connection.original;
	let remote = ident.direction == 'inbound' ? original.source : original.destination;
	let family = connection.family;

	if (ident.direction == 'inbound' && wan[original.destination])
		return { path: wan[original.destination], evidence: 'conntrack', confidence: 'high', natSource: original.destination };

	if (wan[connection.reply.destination])
		return { path: wan[connection.reply.destination], evidence: 'conntrack', confidence: 'high', natSource: connection.reply.destination };

	if (wan[original.source])
		return { path: wan[original.source], evidence: 'conntrack', confidence: 'high', natSource: original.source };

	if (util.is_link_scoped(remote) || util.is_tailscale_destination(remote) ||
	    ctx.routerAddresses[remote] || discovery.segment_for_ip(ctx.topology, remote))
		return { path: 'local', evidence: 'route', confidence: 'high', localReason: util.is_tailscale_destination(remote) ? 'tailscale' : 'segment' };

	let marked = exit_for_mark(connection.mark, family, ctx);

	if (marked)
		return { path: marked.path, evidence: 'mark', confidence: 'high', table: marked.table };

	let cache_key = `${family}|${remote}`;

	if (ctx.routeCache[cache_key] == null)
		ctx.routeCache[cache_key] =
			route_device(family == 'ipv6' ? ctx.mainRoutes6 : ctx.mainRoutes4, remote) || false;

	let route = ctx.routeCache[cache_key];

	if (route)
		return {
			path: ctx.topology.deviceMap[route.device] || 'local',
			evidence: 'route',
			confidence: 'medium',
			localReason: 'route'
		};

	let fallback = ctx.topology.defaultExit[family];

	return fallback
		? { path: fallback, evidence: 'route', confidence: 'medium' }
		: { path: 'unknown', evidence: 'none', confidence: 'unknown' };
}

/* ---------- why ---------- */

function reason_for(observed, configured_result) {
	if (observed.path == 'local')
		return observed.localReason == 'tailscale' ? '目标是 Tailscale 网段' :
			observed.localReason == 'route' ? '路由表指向非 WAN 接口' : '目标在本地网段';

	if (configured_result.ruleName && configured_result.basis != 'default_route')
		return `命中「${configured_result.ruleName}」`;

	if (observed.path == 'unknown')
		return '没有足够数据确认出口';

	return '未命中规则，按默认路由';
}

function limitations_for(connection, observed, configured_result) {
	let result = [];
	let port = connection.original.destinationPort;

	if (port == 443 || port == 853)
		push(result, '加密 DNS / HTTPS 无法还原域名，域名规则只按已解析 IP 判断');

	if (length(configured_result.missingInterfaces))
		push(result, `规则引用的接口不存在：${join(', ', configured_result.missingInterfaces)}`);

	if (observed.confidence == 'medium' && observed.evidence == 'route')
		push(result, '出口由路由表推断，未在连接跟踪中看到 NAT 地址');

	return result;
}

function is_mismatch(configured_result, observed_path, exit_ids) {
	return length(configured_result.exits) > 0 &&
		exit_ids[observed_path] &&
		index(configured_result.exits, observed_path) < 0;
}

/* ---------- build ---------- */

function build_flow(connection, ctx) {
	let ident = identify(connection, ctx);
	let endpoint = endpoint_of(ident, ctx.topology);
	let observed = observe(connection, ident, ctx);
	let matched = policy.attribute(ctx.policy, {
		connection,
		mac: endpoint.mac,
		sourceIp: endpoint.ip
	});
	let configured_result = policy.configured(matched, connection.family, ctx.topology);
	let previous = ctx.previousCounters[connection.id];
	let elapsed = previous ? max(1, ctx.sampleAt - previous.sampleAt) : 0;
	let delta = (now_value, before) => previous ? max(0, now_value - before) : 0;
	let delta_bytes = delta(connection.totalBytes, previous?.totalBytes);
	let delta_packets = delta(connection.totalPackets, previous?.totalPackets);

	ctx.nextCounters[connection.id] = {
		sampleAt: ctx.sampleAt,
		totalBytes: connection.totalBytes,
		totalPackets: connection.totalPackets,
		originalBytes: connection.original.bytes,
		replyBytes: connection.reply.bytes
	};

	return {
		timestamp: ctx.sampleAt,
		flowId: connection.id,
		family: connection.family,
		device: endpoint,
		protocol: connection.protocol,
		srcPort: connection.original.sourcePort,
		destIp: connection.original.destination,
		destPort: connection.original.destinationPort,
		originalSource: connection.original.source,
		direction: ident.direction,
		bytesPerSecond: elapsed ? delta_bytes / elapsed : 0,
		packetsPerSecond: elapsed ? delta_packets / elapsed : 0,
		txBytesPerSecond: elapsed ? delta(connection.original.bytes, previous?.originalBytes) / elapsed : 0,
		rxBytesPerSecond: elapsed ? delta(connection.reply.bytes, previous?.replyBytes) / elapsed : 0,
		intervalBytes: delta_bytes,
		totalBytes: connection.totalBytes,
		totalPackets: connection.totalPackets,
		configuredPath: configured_result.path,
		configuredExits: configured_result.exits,
		ruleName: configured_result.ruleName,
		ruleProvider: configured_result.provider,
		ruleBasis: configured_result.basis,
		ruleReason: reason_for(observed, configured_result),
		observedPath: observed.path,
		evidence: observed.evidence,
		confidence: matched && observed.confidence == 'high' && matched.confidence == 'high'
			? 'high' : observed.confidence,
		natSource: observed.natSource || null,
		routeTable: observed.table || null,
		firewallMark: connection.mark,
		connectionState: connection.state,
		timeoutSeconds: connection.timeout,
		mismatch: !!is_mismatch(configured_result, observed.path, ctx.exitIds),
		limitations: limitations_for(connection, observed, configured_result)
	};
}

/*
 * ctx needs: sampleAt, topology, devices, policy (prepared), routes, ipRules,
 *            sockets, listeners, previousCounters
 */
function build_context(input) {
	let main4 = [];
	let main6 = [];
	let table_defaults = [];

	for (let route in input.routes || []) {
		let is_default = route.destination == 'default' || route.destination == '0.0.0.0/0' ||
			route.destination == '::/0';

		if (route.type && route.type != 'unicast')
			continue;

		if (is_default) {
			if (`${route.table}` != 'main')
				push(table_defaults, { family: route.family, table: `${route.table}`, device: route.device });
			continue;
		}

		if (`${route.table}` != 'main' || !route.device)
			continue;

		let entry = {
			cidr: route.destination,
			prefix: util.prefix_length(route.destination),
			device: route.device
		};

		push(route.family == 'ipv6' ? main6 : main4, entry);
	}

	let router_addresses = { ...input.topology.routerAddresses };

	for (let route in input.routes || [])
		if (route.type == 'local' && route.destination)
			router_addresses[split(route.destination, '/')[0]] = true;

	let exit_ids = {};

	for (let exit in input.topology.exits)
		exit_ids[exit.id] = true;

	return {
		sampleAt: input.sampleAt,
		topology: input.topology,
		devicesByIp: index_devices(input.devices),
		routerAddresses: router_addresses,
		policy: input.policy,
		ipRules: input.ipRules || [],
		tableDefaults: table_defaults,
		mainRoutes4: main4,
		mainRoutes6: main6,
		routeCache: {},
		sockets: socket_index(input.sockets, input.listeners),
		previousCounters: input.previousCounters || {},
		nextCounters: {},
		exitIds: exit_ids
	};
}

/*
 * Keep the busiest connections as individual flows and fold the long tail
 * into per device/protocol/path/rule groups, so rule attribution survives.
 */
function aggregate(flows) {
	if (length(flows) <= MAX_FLOWS)
		return flows;

	sort(flows, (a, b) => (b.bytesPerSecond - a.bytesPerSecond) || (b.totalBytes - a.totalBytes));

	let detailed = slice(flows, 0, DETAILED_FLOWS);
	let grouped = {};

	for (let flow in slice(flows, DETAILED_FLOWS)) {
		let key = join('|', [
			flow.device.key, flow.family, flow.protocol, flow.observedPath,
			flow.configuredPath, flow.direction, flow.ruleName || ''
		]);
		let group = grouped[key];

		if (!group)
			group = grouped[key] = {
				...flow,
				flowId: `aggregate|${key}`,
				destIp: null,
				destPort: 0,
				srcPort: 0,
				natSource: null,
				aggregated: true,
				aggregatedFlowCount: 0,
				bytesPerSecond: 0,
				packetsPerSecond: 0,
				txBytesPerSecond: 0,
				rxBytesPerSecond: 0,
				intervalBytes: 0,
				totalBytes: 0,
				totalPackets: 0
			};

		group.aggregatedFlowCount++;

		for (let field in [ 'bytesPerSecond', 'packetsPerSecond', 'txBytesPerSecond',
		                    'rxBytesPerSecond', 'intervalBytes', 'totalBytes', 'totalPackets' ])
			group[field] += flow[field];

		if (util.confidence_rank(flow.confidence) < util.confidence_rank(group.confidence))
			group.confidence = flow.confidence;
	}

	let rest = values(grouped);
	sort(rest, (a, b) => b.bytesPerSecond - a.bytesPerSecond);

	return [ ...detailed, ...slice(rest, 0, MAX_FLOWS - DETAILED_FLOWS) ];
}

/* ---------- statistics ---------- */

function count_of(flow) {
	return flow.aggregatedFlowCount || 1;
}

function summarize_paths(paths, exit_ids) {
	let exits = filter(keys(paths), (path) => exit_ids[path]);

	if (length(exits) > 1)
		return 'mixed';
	if (length(exits))
		return exits[0];
	if (paths.unknown)
		return 'unknown';
	if (paths.local)
		return 'local';

	return 'unknown';
}

/*
 * Attach live statistics to devices and add pseudo devices (router, router
 * processes, unlisted hosts) that appear in flows.
 */
function apply_stats(devices, flows, ctx, policy_prepared, history_samples) {
	let by_key = {};

	for (let device in devices) {
		device.name = device.hostname || device.ipv4 || device.mac;
		device.configured = policy.device_summary(policy_prepared.state, device, ctx.topology);
		by_key[device.key] = device;
	}

	for (let device in devices) {
		device.activeConnections = 0;
		device.mismatchConnections = 0;
		device.bytesPerSecond = 0;
		device.packetsPerSecond = 0;
		device.lastMinuteBytes = 0;
		device.paths = {};
		device.confidence = 'unknown';
	}

	for (let flow in flows) {
		let device = by_key[flow.device.key];

		if (!device) {
			device = by_key[flow.device.key] = {
				key: flow.device.key,
				kind: flow.device.kind,
				name: flow.device.name,
				mac: null,
				hostname: flow.device.name,
				ipv4: util.is_ipv6(flow.device.ip) ? null : flow.device.ip,
				ipv6: [],
				segment: flow.device.segment,
				online: true,
				configured: policy.configured(null, 'ipv4', ctx.topology),
				activeConnections: 0,
				mismatchConnections: 0,
				bytesPerSecond: 0,
				packetsPerSecond: 0,
				lastMinuteBytes: 0,
				paths: {},
				confidence: 'unknown'
			};
			push(devices, device);
		}

		let count = count_of(flow);

		if (!device.paths[flow.observedPath])
			device.paths[flow.observedPath] = { bps: 0, pps: 0, flows: 0 };

		let path = device.paths[flow.observedPath];

		path.bps += flow.bytesPerSecond;
		path.pps += flow.packetsPerSecond;
		path.flows += count;
		device.activeConnections += count;
		device.bytesPerSecond += flow.bytesPerSecond;
		device.packetsPerSecond += flow.packetsPerSecond;
		device.online = true;

		if (flow.mismatch)
			device.mismatchConnections += count;

		if (util.confidence_rank(flow.confidence) > util.confidence_rank(device.confidence))
			device.confidence = flow.confidence;
	}

	let cutoff = util.now() - 60;

	for (let sample in history_samples || [])
		if (sample.timestamp >= cutoff)
			for (let link in sample.links || [])
				if (by_key[link.device])
					by_key[link.device].lastMinuteBytes += link.bytes || 0;

	for (let device in devices)
		device.observedPath = summarize_paths(device.paths, ctx.exitIds);

	sort(devices, (a, b) =>
		(b.bytesPerSecond - a.bytesPerSecond) ||
		(b.activeConnections - a.activeConnections) ||
		((a.name || '') < (b.name || '') ? -1 : 1)
	);

	return devices;
}

function new_group(id, name, kind, device, cidrs) {
	return {
		id,
		name,
		kind,
		device,
		cidrs,
		deviceCount: 0,
		activeDevices: 0,
		connections: 0,
		bytesPerSecond: 0,
		traffic: {}
	};
}

function segment_stats(segments, devices) {
	let result = [];
	let groups = {};

	for (let segment in segments) {
		groups[segment.id] = new_group(segment.id, segment.name, 'segment', segment.device, segment.cidrs);
		push(result, groups[segment.id]);
	}

	for (let device in devices) {
		let id = device.segment || 'other';

		if (!groups[id]) {
			if (!device.activeConnections)
				continue;

			groups[id] = new_group(id, id == 'router' ? '路由器' : '其他', id, null, []);
			push(result, groups[id]);
		}

		let group = groups[id];

		group.deviceCount++;
		group.connections += device.activeConnections;
		group.bytesPerSecond += device.bytesPerSecond;

		if (device.activeConnections)
			group.activeDevices++;

		for (let path in keys(device.paths))
			group.traffic[path] = (group.traffic[path] || 0) + device.paths[path].bps;
	}

	return result;
}

/* Ring-buffer sample: one entry per device and observed exit. */
function compact_links(flows) {
	let links = {};

	for (let flow in flows) {
		let key = `${flow.device.key}|${flow.observedPath}`;

		if (!links[key])
			links[key] = {
				device: flow.device.key,
				name: flow.device.name,
				segment: flow.device.segment,
				path: flow.observedPath,
				bps: 0,
				pps: 0,
				bytes: 0,
				flows: 0,
				mismatch: 0
			};

		let link = links[key];

		link.bps += flow.bytesPerSecond;
		link.pps += flow.packetsPerSecond;
		link.bytes += flow.intervalBytes;
		link.flows += count_of(flow);

		if (flow.mismatch)
			link.mismatch += count_of(flow);
	}

	return values(links);
}

function active(flows, limit) {
	let moving = filter(flows, (flow) => flow.bytesPerSecond > 0);

	sort(moving, (a, b) => b.bytesPerSecond - a.bytesPerSecond);

	return slice(moving, 0, limit);
}

return {
	build_devices,
	build_context,
	build_flow,
	aggregate,
	apply_stats,
	segment_stats,
	compact_links,
	active
};
