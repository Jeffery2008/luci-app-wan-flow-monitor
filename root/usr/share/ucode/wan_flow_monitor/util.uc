'use strict';

const fs = require('fs');

function now() {
	return time();
}

function clamp(value, minimum, maximum) {
	let number = +value;

	if (number != number)
		return minimum;

	return max(minimum, min(maximum, number));
}

function safe_text(value, fallback) {
	if (value == null)
		return fallback || '';

	/* JSON encoding and DOM text nodes provide the primary escaping boundary. */
	let text = replace(`${value}`, /[\r\n\t]/g, ' ');

	return substr(text, 0, 256);
}

function safe_device_name(value) {
	let name = safe_text(value, '');

	return match(name, /^[A-Za-z0-9_.:@-]+$/) ? name : null;
}

function read_number(path) {
	let content = fs.readfile(path, 64);

	if (content == null)
		return null;

	let value = +trim(content);

	return value == value ? value : null;
}

function parse_mark(value) {
	if (value == null)
		return 0;

	let text = lc(`${value}`);
	let slash = index(text, '/');

	if (slash >= 0)
		text = substr(text, 0, slash);

	if (substr(text, 0, 2) == '0x')
		return int(substr(text, 2), 16);

	return int(text, 10);
}

function find(array, predicate) {
	for (let item in array || [])
		if (predicate(item))
			return item;

	return null;
}

function unique_push(array, value) {
	if (value != null && index(array, value) < 0)
		push(array, value);
}

/* UCI options may be a list or a whitespace separated string. */
function as_list(value) {
	if (value == null)
		return [];

	let items = type(value) == 'array' ? value : split(`${value}`, /\s+/);
	let result = [];

	for (let item in items) {
		item = trim(`${item}`);

		if (item != '')
			push(result, safe_text(item, ''));
	}

	return result;
}

function is_ipv6(address) {
	return address != null && index(`${address}`, ':') >= 0;
}

function is_mac(value) {
	return value != null && !!match(`${value}`, /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/);
}

function ip_in_cidr(address, cidr) {
	if (!address || !cidr)
		return false;

	let parts = split(`${cidr}`, '/');
	let ip = iptoarr(`${address}`);
	let network = iptoarr(parts[0]);

	if (!ip || !network || length(ip) != length(network))
		return false;

	let bits = parts[1] != null ? int(parts[1]) : length(ip) * 8;

	if (bits < 0 || bits > length(ip) * 8)
		return false;

	for (let i = 0; i < length(ip); i++) {
		let remaining = bits - (i * 8);

		if (remaining <= 0)
			break;

		let mask = remaining >= 8 ? 255 : ((255 << (8 - remaining)) & 255);

		if ((ip[i] & mask) != (network[i] & mask))
			return false;
	}

	return true;
}

/* "192.168.1.1", 24 -> "192.168.1.0/24" */
function network_cidr(address, bits) {
	let ip = iptoarr(`${address}`);

	if (!ip)
		return null;

	bits = int(bits);

	for (let i = 0; i < length(ip); i++) {
		let remaining = bits - (i * 8);
		let mask = remaining >= 8 ? 255 : remaining <= 0 ? 0 : ((255 << (8 - remaining)) & 255);

		ip[i] = ip[i] & mask;
	}

	return `${arrtoip(ip)}/${bits}`;
}

function prefix_length(cidr) {
	let parts = split(`${cidr}`, '/');

	return parts[1] != null ? int(parts[1]) : (is_ipv6(parts[0]) ? 128 : 32);
}

function bytes_compare(a, b) {
	if (!a || !b || length(a) != length(b))
		return null;

	for (let i = 0; i < length(a); i++)
		if (a[i] != b[i])
			return a[i] < b[i] ? -1 : 1;

	return 0;
}

function ip_compare(left, right) {
	return bytes_compare(iptoarr(`${left}`), iptoarr(`${right}`));
}

/* Prefix test on pre-parsed byte arrays (see policy.prepare). */
function bytes_in_prefix(ip, network, bits) {
	if (!ip || !network || length(ip) != length(network))
		return false;

	for (let i = 0; i < length(ip); i++) {
		let remaining = bits - (i * 8);

		if (remaining <= 0)
			break;

		let mask = remaining >= 8 ? 255 : ((255 << (8 - remaining)) & 255);

		if ((ip[i] & mask) != (network[i] & mask))
			return false;
	}

	return true;
}

/*
 * Never routed to a WAN: loopback, link-local, multicast, broadcast.
 * String prefixes instead of CIDR math: this runs several times per connection.
 */
function is_link_scoped(address) {
	address = lc(`${address ?? ''}`);

	if (index(address, ':') >= 0)
		return address == '::1' || address == '::' || substr(address, 0, 2) == 'ff' ||
			match(address, /^fe[89ab]/) != null;

	let first = int(split(address, '.')[0]);

	return first == 127 || first == 0 || (first >= 224 && first <= 239) ||
		address == '255.255.255.255' || substr(address, 0, 8) == '169.254.';
}

function is_tailscale_destination(address) {
	return ip_in_cidr(address, '100.64.0.0/10') ||
		ip_in_cidr(address, 'fd7a:115c:a1e0::/48');
}

function flow_id(protocol, source, source_port, destination, destination_port) {
	return join('|', [
		lc(protocol || 'unknown'),
		source || '',
		source_port || 0,
		destination || '',
		destination_port || 0
	]);
}

function confidence_rank(value) {
	switch (value) {
	case 'high':
		return 3;
	case 'medium':
		return 2;
	case 'low':
		return 1;
	default:
		return 0;
	}
}

function structured_error(source, code, message, using_cached_data) {
	return {
		source,
		code,
		message: safe_text(message, '未知错误'),
		occurredAt: now(),
		usingCachedData: !!using_cached_data
	};
}

function source_status(cache_entry, ttl) {
	if (!cache_entry)
		return {
			updatedAt: 0,
			ageSeconds: null,
			stale: true,
			error: null
		};

	let age = max(0, now() - (cache_entry.updatedAt || 0));

	return {
		updatedAt: cache_entry.updatedAt || 0,
		lastAttemptAt: cache_entry.lastAttemptAt || 0,
		ageSeconds: age,
		stale: !cache_entry.updatedAt || age > ttl,
		error: cache_entry.error || null
	};
}

return {
	now,
	clamp,
	safe_text,
	safe_device_name,
	read_number,
	parse_mark,
	find,
	unique_push,
	as_list,
	is_ipv6,
	is_mac,
	ip_in_cidr,
	network_cidr,
	prefix_length,
	bytes_compare,
	ip_compare,
	bytes_in_prefix,
	is_link_scoped,
	is_tailscale_destination,
	flow_id,
	confidence_rank,
	structured_error,
	source_status
};
