'use strict';

const util = require('wan_flow_monitor.util');

const CONNECTION_STATES = {
	ESTABLISHED: true,
	SYN_SENT: true,
	SYN_RECV: true,
	FIN_WAIT: true,
	CLOSE_WAIT: true,
	LAST_ACK: true,
	TIME_WAIT: true,
	CLOSE: true,
	LISTEN: true,
	UNREPLIED: true,
	ASSURED: true
};

function parse_json(text) {
	if (text == null || trim(text) == '')
		return [];

	return json(text);
}

function parse_dhcp_leases(text, timestamp) {
	let leases = [];

	for (let line in split(text || '', '\n')) {
		let match_line = match(trim(line), /^(\d+)\s+([0-9a-fA-F:]{17})\s+(\S+)\s+(\S+)(\s+(\S+))?/);

		if (!match_line)
			continue;

		let expires = int(match_line[1]);

		push(leases, {
			expiresAt: expires,
			remainingSeconds: expires == 0 ? null : max(0, expires - timestamp),
			mac: uc(match_line[2]),
			ipv4: match_line[3] == '*' ? null : match_line[3],
			hostname: match_line[4] == '*' ? null : util.safe_text(match_line[4], null),
			clientId: match_line[6] == '*' ? null : util.safe_text(match_line[6], null)
		});
	}

	return leases;
}

function parse_neighbours(data) {
	let neighbours = [];

	for (let entry in data || []) {
		if (!entry.dst)
			continue;

		push(neighbours, {
			ip: util.safe_text(entry.dst, null),
			mac: entry.lladdr ? uc(util.safe_text(entry.lladdr, '')) : null,
			device: util.safe_text(entry.dev, null),
			state: type(entry.state) == 'array'
				? join(',', entry.state)
				: util.safe_text(entry.state, 'UNKNOWN'),
			router: !!entry.router
		});
	}

	return neighbours;
}

function parse_conntrack(text) {
	let connections = [];

	for (let line in split(text || '', '\n')) {
		line = trim(line);

		if (!line)
			continue;

		let tokens = split(line, /\s+/);
		let protocol_index = -1;

		for (let i = 0; i < min(length(tokens), 6); i++) {
			if (tokens[i] == 'tcp' || tokens[i] == 'udp' ||
			    tokens[i] == 'icmp' || tokens[i] == 'icmpv6') {
				protocol_index = i;
				break;
			}
		}

		if (protocol_index < 0)
			continue;

		let protocol = tokens[protocol_index];
		let fields = {
			src: [],
			dst: [],
			sport: [],
			dport: [],
			packets: [],
			bytes: []
		};
		let mark_value = 0;
		let state = protocol == 'udp' ? 'ACTIVE' : 'UNKNOWN';
		let timeout = int(tokens[protocol_index + 2]);

		for (let token in tokens) {
			if (CONNECTION_STATES[token])
				state = token;

			let equals = index(token, '=');

			if (equals <= 0)
				continue;

			let key = substr(token, 0, equals);
			let value = substr(token, equals + 1);

			if (fields[key] != null)
				push(fields[key], value);
			else if (key == 'mark')
				mark_value = util.parse_mark(value);
		}

		if (length(fields.src) < 2 || length(fields.dst) < 2)
			continue;

		let original_packets = int(fields.packets[0] || 0);
		let reply_packets = int(fields.packets[1] || 0);
		let original_bytes = int(fields.bytes[0] || 0);
		let reply_bytes = int(fields.bytes[1] || 0);
		let original_source_port = int(fields.sport[0] || 0);
		let original_destination_port = int(fields.dport[0] || 0);

		push(connections, {
			id: util.flow_id(
				protocol,
				fields.src[0],
				original_source_port,
				fields.dst[0],
				original_destination_port
			),
			family: util.is_ipv6(fields.src[0]) ? 'ipv6' : 'ipv4',
			protocol,
			timeout: timeout == timeout ? timeout : null,
			state,
			mark: mark_value == mark_value ? mark_value : 0,
			original: {
				source: fields.src[0],
				destination: fields.dst[0],
				sourcePort: original_source_port,
				destinationPort: original_destination_port,
				packets: original_packets,
				bytes: original_bytes
			},
			reply: {
				source: fields.src[1],
				destination: fields.dst[1],
				sourcePort: int(fields.sport[1] || 0),
				destinationPort: int(fields.dport[1] || 0),
				packets: reply_packets,
				bytes: reply_bytes
			},
			totalPackets: original_packets + reply_packets,
			totalBytes: original_bytes + reply_bytes
		});
	}

	return connections;
}

function parse_endpoint(value) {
	let text = value || '';
	let bracketed = match(text, /^\[([^\]]+)\]:(\*|\d+)$/);

	if (bracketed) {
		let address = bracketed[1];
		let zone = index(address, '%');

		if (zone >= 0)
			address = substr(address, 0, zone);

		/* Dual-stack sockets report IPv4 peers as ::ffff:a.b.c.d */
		let mapped = match(address, /^::ffff:([0-9.]+)$/);

		if (mapped)
			address = mapped[1];

		return {
			address,
			port: bracketed[2] == '*' ? 0 : int(bracketed[2])
		};
	}

	let ordinary = match(text, /^(.*):(\*|\d+)$/);

	if (!ordinary)
		return { address: text, port: 0 };

	let address = ordinary[1] == '*' ? '0.0.0.0' : ordinary[1];
	let zone = index(address, '%');

	if (zone >= 0)
		address = substr(address, 0, zone);

	let mapped = match(address, /^::ffff:([0-9.]+)$/);

	if (mapped)
		address = mapped[1];

	return {
		address,
		port: ordinary[2] == '*' ? 0 : int(ordinary[2])
	};
}

function parse_ss(text) {
	let sockets = [];

	for (let line in split(text || '', '\n')) {
		let tokens = split(trim(line), /\s+/);

		if (length(tokens) < 6)
			continue;

		let process = '';

		for (let i = 6; i < length(tokens); i++)
			process += (process ? ' ' : '') + tokens[i];

		let pid_match = match(process, /pid=(\d+)/);
		let name_match = match(process, /\(\("([^"]+)"/);

		push(sockets, {
			protocol: lc(tokens[0]),
			state: uc(tokens[1]),
			receiveQueue: int(tokens[2]) || 0,
			sendQueue: int(tokens[3]) || 0,
			local: parse_endpoint(tokens[4]),
			peer: parse_endpoint(tokens[5]),
			processName: name_match ? util.safe_text(name_match[1], null) : null,
			pid: pid_match ? int(pid_match[1]) : null,
			processVisible: !!process
		});
	}

	return sockets;
}

function nft_find_mark(node) {
	if (node == null)
		return null;

	if (type(node) == 'object') {
		let target = node.goto?.target || node.jump?.target;

		if (target) {
			let chain_mark = match(target, /^pbr_mark_0x([0-9a-fA-F]+)$/);

			if (chain_mark)
				return int(chain_mark[1], 16);
		}

		if (node.mangle?.key?.meta?.key == 'mark' &&
		    type(node.mangle.value) == 'int')
			return node.mangle.value;

		for (let key in keys(node)) {
			let found = nft_find_mark(node[key]);

			if (found != null)
				return found;
		}
	}
	else if (type(node) == 'array') {
		for (let child in node) {
			let found = nft_find_mark(child);

			if (found != null)
				return found;
		}
	}

	return null;
}

function nft_find_counter(node) {
	if (node == null)
		return null;

	if (type(node) == 'object') {
		if (node.counter && type(node.counter) == 'object')
			return {
				packets: int(node.counter.packets || 0),
				bytes: int(node.counter.bytes || 0)
			};

		for (let key in keys(node)) {
			let found = nft_find_counter(node[key]);

			if (found)
				return found;
		}
	}
	else if (type(node) == 'array') {
		for (let child in node) {
			let found = nft_find_counter(child);

			if (found)
				return found;
		}
	}

	return null;
}

function nft_collect_set_refs(node, refs) {
	if (type(node) == 'string') {
		if (substr(node, 0, 1) == '@')
			push(refs, substr(node, 1));
	}
	else if (type(node) == 'object') {
		for (let key in keys(node))
			nft_collect_set_refs(node[key], refs);
	}
	else if (type(node) == 'array') {
		for (let child in node)
			nft_collect_set_refs(child, refs);
	}

	return refs;
}

function nft_set_elements(elements) {
	let result = [];

	for (let element in elements || []) {
		if (type(element) == 'string')
			push(result, { type: 'address', value: element });
		else if (element?.prefix)
			push(result, {
				type: 'prefix',
				value: `${element.prefix.addr}/${element.prefix.len}`
			});
		else if (type(element?.range) == 'array')
			push(result, {
				type: 'range',
				from: element.range[0],
				to: element.range[1]
			});
	}

	return result;
}

function parse_nft(data) {
	let rules = [];
	let sets = {};
	let items = data?.nftables || data || [];

	for (let item in items) {
		if (item?.set?.name) {
			/* Only PBR destination sets are needed for rule attribution. */
			if (index(item.set.name, 'pbr_') == 0)
				sets[item.set.name] = nft_set_elements(item.set.elem);

			continue;
		}

		let rule = item?.rule;

		if (!rule)
			continue;

		let mark_value = nft_find_mark(rule.expr);
		let counter = nft_find_counter(rule.expr);
		let comment = util.safe_text(rule.comment, null);

		if (mark_value == null && !counter && !comment)
			continue;

		push(rules, {
			family: util.safe_text(rule.family, null),
			table: util.safe_text(rule.table, null),
			chain: util.safe_text(rule.chain, null),
			handle: int(rule.handle || 0),
			comment,
			mark: mark_value,
			setRefs: nft_collect_set_refs(rule.expr, []),
			counter: counter || { packets: 0, bytes: 0 }
		});
	}

	return { rules, sets };
}

function parse_ip_rules(data, family) {
	let rules = [];

	for (let entry in data || []) {
		push(rules, {
			family,
			priority: int(entry.priority || entry.pref || 0),
			source: util.safe_text(entry.from, 'all'),
			destination: util.safe_text(entry.to, 'all'),
			fwmark: entry.fwmark != null ? util.parse_mark(entry.fwmark) : null,
			fwmask: entry.fwmask != null ? util.parse_mark(entry.fwmask) : null,
			table: util.safe_text(entry.table, null),
			action: util.safe_text(entry.action, 'lookup')
		});
	}

	return rules;
}

function parse_routes(data, family) {
	let routes = [];

	for (let entry in data || []) {
		push(routes, {
			family,
			destination: util.safe_text(entry.dst, 'default'),
			gateway: util.safe_text(entry.gateway, null),
			device: util.safe_text(entry.dev, null),
			source: util.safe_text(entry.prefsrc, null),
			metric: int(entry.metric || 0),
			table: util.safe_text(entry.table, 'main'),
			protocol: util.safe_text(entry.protocol, null),
			type: util.safe_text(entry.type, 'unicast')
		});
	}

	return routes;
}

return {
	parse_json,
	parse_dhcp_leases,
	parse_neighbours,
	parse_conntrack,
	parse_ss,
	parse_nft,
	parse_ip_rules,
	parse_routes
};
