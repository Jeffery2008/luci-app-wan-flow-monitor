'use strict';

/*
 * Routing policy providers normalized into one ordered rule list.
 *
 *   pbr    /etc/config/pbr policy sections. When pbr's nft rules are loaded
 *          (rule comment == policy name) they are evaluated in nft order and
 *          their domain sets are used; otherwise the UCI fields are matched.
 *   mwan3  /etc/config/mwan3 rule -> policy -> member -> interface. The
 *          lowest-metric members of a policy are its configured exits.
 *
 * Only routing fields are read; nothing here can reach credentials.
 */

const util = require('wan_flow_monitor.util');

function enabled(value) {
	return value == null || (`${value}` != '0' && `${value}` != 'false');
}

function is_address(value) {
	return !!iptoarr(split(`${value}`, '/')[0]);
}

function pbr_rules(config) {
	let rules = [];
	let order = 0;

	for (let section in config?.policies || []) {
		let iface = util.safe_text(section.interface, '');
		let destinations = util.as_list(section.dest_addr);

		push(rules, {
			id: `pbr:${util.safe_text(section['.name'], order)}`,
			provider: 'pbr',
			name: util.safe_text(section.name, `pbr 规则 ${order + 1}`),
			order: order++,
			enabled: enabled(section.enabled),
			interfaces: iface && iface != 'ignore' ? [ iface ] : [],
			target: iface == 'ignore' ? 'ignore' : 'exit',
			protocols: util.as_list(section.proto),
			family: 'any',
			sourceAddresses: util.as_list(section.src_addr),
			sourcePorts: util.as_list(section.src_port),
			destinationAddresses: destinations,
			destinationPorts: util.as_list(section.dest_port),
			hasDomains: !!util.find(destinations, (value) => !is_address(value)),
			chain: util.safe_text(section.chain, 'prerouting')
		});
	}

	return rules;
}

function mwan3_rules(config) {
	let members = {};
	let policies = {};
	let interfaces = {};
	let rules = [];
	let order = 0;

	for (let section in config?.interfaces || [])
		interfaces[section['.name']] = enabled(section.enabled);

	for (let section in config?.members || [])
		members[section['.name']] = {
			interface: util.safe_text(section.interface, ''),
			metric: int(section.metric || 1),
			weight: int(section.weight || 1)
		};

	for (let section in config?.policies || [])
		policies[section['.name']] = util.as_list(section.use_member);

	for (let section in config?.rules || []) {
		let use_policy = util.safe_text(section.use_policy, 'default');
		let target = 'exit';
		let exits = [];

		if (use_policy == 'default')
			target = 'default';
		else if (use_policy == 'unreachable' || use_policy == 'blackhole')
			target = 'blocked';
		else {
			let candidates = filter(
				map(policies[use_policy] || [], (name) => members[name]),
				(member) => member && member.interface && interfaces[member.interface] !== false
			);
			let best = null;

			for (let member in candidates)
				if (best == null || member.metric < best)
					best = member.metric;

			for (let member in candidates)
				if (member.metric == best)
					util.unique_push(exits, member.interface);
		}

		push(rules, {
			id: `mwan3:${util.safe_text(section['.name'], order)}`,
			provider: 'mwan3',
			name: util.safe_text(section['.name'], `mwan3 规则 ${order + 1}`),
			policyName: use_policy,
			order: order++,
			enabled: true,
			interfaces: exits,
			target,
			protocols: section.proto && section.proto != 'all' ? util.as_list(section.proto) : [],
			family: util.safe_text(section.family, 'any'),
			sourceAddresses: util.as_list(section.src_ip),
			sourcePorts: util.as_list(section.src_port),
			destinationAddresses: util.as_list(section.dest_ip),
			destinationPorts: util.as_list(section.dest_port),
			hasDomains: !!section.ipset,
			chain: 'any'
		});
	}

	return rules;
}

/*
 * raw: { pbr: { enabled, policies: [sections] } | null,
 *        mwan3: { interfaces, members, policies, rules } | null }
 */
function load(raw) {
	let providers = [];
	let rules = [];

	if (raw?.pbr) {
		let list = pbr_rules(raw.pbr);
		push(providers, { id: 'pbr', enabled: enabled(raw.pbr.enabled), ruleCount: length(list) });
		if (enabled(raw.pbr.enabled))
			rules = [ ...rules, ...list ];
	}

	if (raw?.mwan3) {
		let list = mwan3_rules(raw.mwan3);
		push(providers, { id: 'mwan3', enabled: enabled(raw.mwan3.enabled), ruleCount: length(list) });
		if (enabled(raw.mwan3.enabled))
			rules = [ ...rules, ...list ];
	}

	let referenced = [];

	for (let rule in rules)
		for (let name in rule.interfaces)
			util.unique_push(referenced, name);

	return { providers, rules, referencedInterfaces: referenced };
}

/* Map the rule's interface names onto discovered exits. */
function resolve(policy_state, topology) {
	for (let rule in policy_state.rules) {
		rule.exits = [];
		rule.missingInterfaces = [];

		for (let name in rule.interfaces) {
			let exit = topology.aliasMap[name];

			if (exit)
				util.unique_push(rule.exits, exit);
			else
				push(rule.missingInterfaces, name);
		}
	}

	return policy_state;
}

function port_matches(port, expressions) {
	if (!length(expressions))
		return true;

	for (let expression in expressions)
		for (let part in split(expression, ',')) {
			let range = match(trim(part), /^(\d+)([:-](\d+))?$/);

			if (!range)
				continue;

			let from = int(range[1]);
			let to = range[3] ? int(range[3]) : from;

			if (port >= from && port <= to)
				return true;
		}

	return false;
}

function protocol_matches(protocol, protocols) {
	if (!length(protocols))
		return true;

	for (let candidate in protocols)
		if (candidate == 'all' || lc(candidate) == lc(protocol))
			return true;

	return false;
}

function address_matches(address, entries) {
	for (let entry in entries) {
		if (!is_address(entry))
			continue;

		if (entry == address || (index(entry, '/') >= 0 && util.ip_in_cidr(address, entry)))
			return true;
	}

	return false;
}

function source_matches(rule, mac, ip) {
	if (!length(rule.sourceAddresses))
		return true;

	for (let source in rule.sourceAddresses)
		if (mac && util.is_mac(source) && uc(source) == uc(mac))
			return true;

	return !!ip && address_matches(ip, rule.sourceAddresses);
}

function rule_conditions(rule, flow) {
	let connection = flow.connection;

	/* prerouting rules never see traffic originated by the router itself. */
	if (rule.chain == 'prerouting' && !flow.mac)
		return false;

	if (rule.family != 'any' && rule.family != connection.family)
		return false;

	if (!source_matches(rule, flow.mac, flow.sourceIp))
		return false;

	if (!protocol_matches(connection.protocol, rule.protocols))
		return false;

	if (!port_matches(connection.original.sourcePort, rule.sourcePorts))
		return false;

	if (!port_matches(connection.original.destinationPort, rule.destinationPorts))
		return false;

	if (!length(rule.destinationAddresses))
		return !rule.hasDomains;

	return address_matches(connection.original.destination, rule.destinationAddresses);
}

/* A rule whose interface does not exist is not installed by pbr/mwan3 either. */
function rule_applies(rule, flow) {
	if (!rule.enabled || (rule.target == 'exit' && !length(rule.exits)))
		return false;

	return rule_conditions(rule, flow);
}

/* nft set elements -> exact-address map plus pre-parsed prefixes and ranges. */
function compile_set(elements) {
	let compiled = { addresses: {}, prefixes: [], ranges: [] };

	for (let element in elements || []) {
		if (element.type == 'address')
			compiled.addresses[element.value] = true;
		else if (element.type == 'prefix') {
			let parts = split(element.value, '/');
			push(compiled.prefixes, { network: iptoarr(parts[0]), bits: int(parts[1]) });
		}
		else if (element.type == 'range')
			push(compiled.ranges, { from: iptoarr(element.from), to: iptoarr(element.to) });
	}

	return compiled;
}

function ip_in_set(address, bytes, set) {
	if (!set)
		return false;

	if (set.addresses[address])
		return true;

	for (let prefix in set.prefixes)
		if (util.bytes_in_prefix(bytes, prefix.network, prefix.bits))
			return true;

	for (let range in set.ranges) {
		let low = util.bytes_compare(bytes, range.from);
		let high = util.bytes_compare(bytes, range.to);

		if (low != null && high != null && low >= 0 && high <= 0)
			return true;
	}

	return false;
}

/* pbr rules as installed in nft: order, chains and resolved domain sets. */
function attribute_pbr_nft(flow, prepared) {
	let connection = flow.connection;

	for (let nft_rule in prepared.pbrNftRules) {
		if (nft_rule.chain == 'pbr_prerouting' && !flow.mac)
			continue;

		let rule = prepared.rulesByName[nft_rule.comment];

		if (!rule || (!nft_rule.mark && rule.target != 'ignore'))
			continue;

		let matched;

		if (length(nft_rule.setRefs)) {
			let destination = connection.original.destination;
			let bytes = iptoarr(destination);

			matched = false;

			for (let name in nft_rule.setRefs)
				if (!matched && ip_in_set(destination, bytes, prepared.sets[name]))
					matched = true;

			matched = matched && protocol_matches(connection.protocol, rule.protocols);
		}
		else {
			matched = rule_conditions({ ...rule, chain: 'any' }, flow);
		}

		if (!matched)
			continue;

		let confirmed = nft_rule.mark && connection.mark &&
			(connection.mark & 0xff0000) == (nft_rule.mark & 0xff0000);

		return { rule, basis: 'nft', confidence: confirmed ? 'high' : 'medium' };
	}

	return null;
}

/* Per-sample lookup tables, so attribute() stays cheap per connection. */
function prepare(policy_state, nft) {
	nft ||= { rules: [], sets: {} };

	let pbr_nft_rules = filter(nft.rules || [], (rule) =>
		rule.comment && index(rule.chain || '', 'pbr_') == 0
	);
	let rules_by_name = {};
	let sets = {};

	for (let rule in policy_state.rules)
		if (rule.provider == 'pbr')
			rules_by_name[rule.name] = rule;

	for (let rule in pbr_nft_rules)
		for (let name in rule.setRefs)
			sets[name] ||= compile_set(nft.sets?.[name]);

	return {
		state: policy_state,
		nft,
		sets,
		pbrNftRules: pbr_nft_rules,
		pbrLoaded: length(pbr_nft_rules) > 0,
		rulesByName: rules_by_name
	};
}

/*
 * flow: { connection, mac, sourceIp }
 * Returns { rule, basis, confidence } for the first matching rule, or null.
 */
function attribute(prepared, flow) {
	if (prepared.pbrLoaded) {
		let found = attribute_pbr_nft(flow, prepared);

		if (found)
			return found;
	}

	for (let rule in prepared.state.rules) {
		if (rule.provider == 'pbr' && prepared.pbrLoaded)
			continue;

		if (rule_applies(rule, flow))
			return { rule, basis: 'uci', confidence: 'medium' };
	}

	return null;
}

/*
 * What the configuration says for one flow:
 *   { path, exits, ruleName, provider, basis }
 * path is an exit id, 'local', 'balanced' (several equal exits) or 'unknown'.
 */
function configured(match_result, family, topology) {
	let fallback = topology.defaultExit?.[family] || topology.defaultExit?.ipv4 || null;
	let rule = match_result?.rule;

	if (!rule || rule.target == 'default')
		return {
			path: fallback || 'unknown',
			exits: fallback ? [ fallback ] : [],
			ruleName: rule?.name || null,
			provider: rule?.provider || null,
			basis: rule ? match_result.basis : 'default_route'
		};

	if (rule.target == 'ignore')
		return { path: 'local', exits: [], ruleName: rule.name, provider: rule.provider, basis: match_result.basis };

	if (rule.target == 'blocked' || !length(rule.exits))
		return {
			path: 'unknown',
			exits: [],
			ruleName: rule.name,
			provider: rule.provider,
			basis: match_result.basis,
			missingInterfaces: rule.missingInterfaces
		};

	return {
		path: length(rule.exits) > 1 ? 'balanced' : rule.exits[0],
		exits: rule.exits,
		ruleName: rule.name,
		provider: rule.provider,
		basis: match_result.basis
	};
}

/* Device-specific rules (source MAC / IP / subnet) for the device list. */
function device_summary(policy_state, device, topology) {
	for (let rule in policy_state.rules) {
		if (!rule.enabled || !length(rule.sourceAddresses))
			continue;

		if (!source_matches(rule, device.mac, device.ipv4))
			continue;

		return configured({ rule, basis: 'uci' }, 'ipv4', topology);
	}

	return configured(null, 'ipv4', topology);
}

/* MACs named by policies: such devices are listed even when offline. */
function policy_macs(policy_state) {
	let macs = [];

	for (let rule in policy_state.rules)
		for (let source in rule.sourceAddresses)
			if (util.is_mac(source))
				util.unique_push(macs, uc(source));

	return macs;
}

return {
	load,
	resolve,
	prepare,
	attribute,
	configured,
	device_summary,
	policy_macs,
	port_matches
};
