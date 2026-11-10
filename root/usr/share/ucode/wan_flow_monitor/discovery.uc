'use strict';

/*
 * Discover the multi-WAN topology from live state, without any hardcoded
 * interface names or subnets:
 *
 *   exits     netifd interfaces that hold a default route, sit in a
 *             masquerading firewall zone, or are referenced by a routing
 *             policy (pbr / mwan3). Interfaces sharing one L3 device
 *             (e.g. wan + wan6) are merged into one exit.
 *   segments  non-WAN interfaces that are up, have IPv4 and either run a
 *             DHCP server or belong to a non-masquerading zone.
 *
 * Pure functions: callers pass ubus/UCI/route data in, tests pass fixtures.
 */

const util = require('wan_flow_monitor.util');

function addresses(iface, key) {
	let result = [];

	for (let entry in iface?.[key] || [])
		if (entry.address)
			push(result, {
				address: util.safe_text(entry.address, null),
				prefix: int(entry.mask || 0)
			});

	return result;
}

function default_routes(iface) {
	let result = { ipv4: null, ipv6: null };

	for (let route in iface?.route || []) {
		if (int(route.mask || 0) != 0)
			continue;

		if (route.target == '0.0.0.0' && !result.ipv4)
			result.ipv4 = route;
		else if (route.target == '::' && !result.ipv6)
			result.ipv6 = route;
	}

	return result;
}

function zone_index(zones) {
	let by_network = {};

	for (let zone in zones || [])
		for (let network in zone.networks || [])
			by_network[network] = zone;

	return by_network;
}

function is_masq_zone(zone) {
	return zone != null && (`${zone.masq}` == '1' || `${zone.masq6}` == '1');
}

/* Lowest-metric default route of the main table, per family. */
function main_default_device(routes, family) {
	let best = null;

	for (let route in routes || []) {
		if (route.family != family || `${route.table || 'main'}` != 'main')
			continue;

		if (route.destination != 'default' && route.destination != '0.0.0.0/0' &&
		    route.destination != '::/0')
			continue;

		if (route.type && route.type != 'unicast')
			continue;

		if (!best || (route.metric || 0) < (best.metric || 0))
			best = route;
	}

	return best?.device || null;
}

function health_of(exit) {
	if (!exit.up || !exit.available)
		return { status: 'down', confidence: 'high' };

	if (!length(exit.ipv4) && !length(exit.ipv6))
		return { status: 'degraded', confidence: 'medium' };

	if (!exit.gateway4 && !exit.gateway6 && !exit.isDefault4 && !exit.isDefault6)
		return { status: 'degraded', confidence: 'medium' };

	return { status: 'healthy', confidence: 'high' };
}

function build_exits(interfaces, zones_by_network, routes, referenced) {
	let groups = {};
	let order = [];

	for (let iface in interfaces) {
		let name = iface.interface;

		if (!name || name == 'loopback' || iface.device == 'lo' || iface.l3_device == 'lo')
			continue;

		let defaults = default_routes(iface);
		let zone = zones_by_network[name];
		let candidate = defaults.ipv4 || defaults.ipv6 || is_masq_zone(zone) ||
			index(referenced || [], name) >= 0;

		if (!candidate)
			continue;

		let key = iface.l3_device || iface.device || `iface:${name}`;

		if (!groups[key]) {
			groups[key] = [];
			push(order, key);
		}

		push(groups[key], { iface, defaults, zone });
	}

	let default4 = main_default_device(routes, 'ipv4');
	let default6 = main_default_device(routes, 'ipv6');
	let exits = [];

	for (let key in order) {
		let members = groups[key];
		let primary = util.find(members, (m) => length(m.iface['ipv4-address'] || [])) ||
			util.find(members, (m) => is_masq_zone(m.zone)) ||
			members[0];
		let device = primary.iface.l3_device || primary.iface.device || null;
		let exit = {
			id: util.safe_text(primary.iface.interface, 'unknown'),
			aliases: [],
			device: util.safe_text(device, null),
			proto: util.safe_text(primary.iface.proto, null),
			zone: util.safe_text(primary.zone?.name, null),
			up: false,
			available: false,
			ipv4: [],
			ipv6: [],
			gateway4: null,
			gateway6: null,
			metric: int(primary.iface.metric || 0),
			isDefault4: !!device && device == default4,
			isDefault6: !!device && device == default6
		};

		for (let member in members) {
			let iface = member.iface;

			push(exit.aliases, util.safe_text(iface.interface, ''));
			exit.up = exit.up || !!iface.up;
			exit.available = exit.available || (iface.available == null ? !!iface.up : !!iface.available);
			exit.ipv4 = [ ...exit.ipv4, ...addresses(iface, 'ipv4-address') ];
			exit.ipv6 = [ ...exit.ipv6, ...addresses(iface, 'ipv6-address') ];
			exit.gateway4 ||= util.safe_text(member.defaults.ipv4?.nexthop, null) || null;
			exit.gateway6 ||= util.safe_text(member.defaults.ipv6?.nexthop, null) || null;
			exit.zone ||= util.safe_text(member.zone?.name, null) || null;
		}

		exit.isDefault = exit.isDefault4 || exit.isDefault6;
		exit.health = health_of(exit);
		push(exits, exit);
	}

	/* Default route first, then by metric and name: stable colors in the UI. */
	let flag = (value) => value ? 1 : 0;

	sort(exits, (a, b) =>
		(flag(b.isDefault4) - flag(a.isDefault4)) ||
		(flag(b.isDefault6) - flag(a.isDefault6)) ||
		(a.metric - b.metric) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
	);

	return exits;
}

function build_segments(interfaces, zones_by_network, dhcp, exit_aliases) {
	let dhcp_served = {};
	let segments = [];

	for (let section in dhcp || [])
		if (section.interface && `${section.ignore}` != '1')
			dhcp_served[section.interface] = true;

	for (let iface in interfaces) {
		let name = iface.interface;

		if (!name || name == 'loopback' || !iface.up || exit_aliases[name])
			continue;

		let ipv4 = addresses(iface, 'ipv4-address');
		let zone = zones_by_network[name];

		if (!length(ipv4))
			continue;

		if (!dhcp_served[name] && !(zone && !is_masq_zone(zone)))
			continue;

		let cidrs = map(ipv4, (entry) => util.network_cidr(entry.address, entry.prefix));

		for (let prefix in iface['ipv6-prefix-assignment'] || [])
			if (prefix.address)
				push(cidrs, util.network_cidr(prefix.address, prefix.mask || 64));

		push(segments, {
			id: util.safe_text(name, 'unknown'),
			name: util.safe_text(name, 'unknown'),
			device: util.safe_text(iface.l3_device || iface.device, null),
			zone: util.safe_text(zone?.name, null),
			cidrs: filter(cidrs, (cidr) => cidr != null),
			gateway: ipv4[0].address
		});
	}

	sort(segments, (a, b) => {
		let compared = util.ip_compare(a.gateway, b.gateway);
		return compared == null ? 0 : compared;
	});

	return segments;
}

/*
 * dump:     ubus network.interface dump
 * config:   { zones: [{ name, networks, masq, masq6 }], dhcp: [{ interface, ignore }] }
 * routes:   parsed `ip -j route show table all`
 * referenced: interface names used by routing policies
 */
function discover(dump, config, routes, referenced) {
	let interfaces = dump?.interface || [];
	let zones_by_network = zone_index(config?.zones);
	let exits = build_exits(interfaces, zones_by_network, routes, referenced);
	let alias_map = {};
	let device_map = {};
	let wan_addresses = {};
	let router_addresses = {};

	for (let exit in exits) {
		for (let alias in exit.aliases)
			alias_map[alias] = exit.id;

		if (exit.device)
			device_map[exit.device] = exit.id;

		for (let entry in [ ...exit.ipv4, ...exit.ipv6 ])
			wan_addresses[entry.address] = exit.id;
	}

	let segments = build_segments(interfaces, zones_by_network, config?.dhcp, alias_map);
	let segment_by_device = {};

	for (let segment in segments)
		if (segment.device)
			segment_by_device[segment.device] = segment.id;

	for (let iface in interfaces)
		for (let entry in [ ...addresses(iface, 'ipv4-address'), ...addresses(iface, 'ipv6-address') ])
			router_addresses[entry.address] = true;

	return {
		exits,
		segments,
		aliasMap: alias_map,
		deviceMap: device_map,
		wanAddresses: wan_addresses,
		routerAddresses: router_addresses,
		segmentByDevice: segment_by_device,
		defaultExit: {
			ipv4: util.find(exits, (exit) => exit.isDefault4)?.id || null,
			ipv6: util.find(exits, (exit) => exit.isDefault6)?.id || null
		}
	};
}

/* Cached per topology object (one per snapshot): called for most connections. */
function segment_for_ip(topology, address) {
	if (!address)
		return null;

	topology.segmentCache ||= {};

	let cached = topology.segmentCache[address];

	if (cached != null)
		return cached || null;

	let found = false;

	for (let segment in topology.segments || [])
		for (let cidr in segment.cidrs)
			if (!found && util.ip_in_cidr(address, cidr))
				found = segment.id;

	topology.segmentCache[address] = found;
	return found || null;
}

return {
	discover,
	segment_for_ip
};
