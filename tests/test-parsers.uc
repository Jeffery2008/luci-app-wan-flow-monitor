'use strict';

const fs = require('fs');
const parsers = require('wan_flow_monitor.parsers');
const util = require('wan_flow_monitor.util');

let fixture_root = getenv('FIXTURE_ROOT') || './tests/fixtures';
let failures = 0;

function check(condition, message) {
	if (condition) {
		print(`ok - ${message}\n`);
		return;
	}

	warn(`not ok - ${message}\n`);
	failures++;
}

function fixture(name) {
	let content = fs.readfile(`${fixture_root}/${name}`);

	if (content == null)
		die(`Unable to read fixture ${name}\n`);

	return content;
}

let leases = parsers.parse_dhcp_leases(fixture('dhcp.leases'), 1893450000);
check(length(leases) == 4, 'parses all DHCP leases');
check(leases[0].mac == 'CC:60:23:4B:A1:EA', 'normalizes MAC addresses');
check(leases[2].ipv4 == '192.168.200.47', 'keeps VLAN200 address');

let neighbours = parsers.parse_neighbours(json(fixture('neigh.json')));
check(length(neighbours) == 4, 'parses IPv4 and IPv6 neighbours');
check(neighbours[3].ip == 'fd00:200::47', 'keeps IPv6 separate');

let connections = parsers.parse_conntrack(fixture('conntrack.txt'));
check(length(connections) == 5, 'parses conntrack records');
check(connections[0].reply.destination == '100.64.1.2',
	'exposes outbound NAT source evidence');
check(connections[1].mark == 65536, 'parses decimal firewall mark');
check(connections[1].family == 'ipv4', 'records address family');
check(connections[4].original.destinationPort == 55555,
	'retains inbound qBittorrent port');

let nft = parsers.parse_nft(json(fixture('nft.json')));
let commented = filter(nft.rules, (rule) => rule.comment);
check(length(commented) == 3, 'parses commented PBR jump rules');
check(commented[0].mark == 0x20000, 'derives mark from goto pbr_mark chain');
check(commented[1].setRefs[0] == 'pbr_wan_sla_4_dst_ip_cfg0b6ff5',
	'records referenced domain IP set');
check(length(nft.sets.pbr_wan_sla_4_dst_ip_cfg0b6ff5) == 3,
	'parses address, prefix and range set elements');

let routes = parsers.parse_routes(json(fixture('routes.json')), 'ipv4');
check(routes[0].device == 'wwan0', 'parses default wwan route');
check(routes[1].table == '100', 'preserves PBR route table');

let rules = parsers.parse_ip_rules(json(fixture('rules.json')), 'ipv4');
check(rules[0].fwmark == 65536, 'parses hexadecimal ip rule mark');
check(rules[0].fwmask == 16711680, 'parses ip rule mask');

let sockets = parsers.parse_ss(fixture('ss.txt'));
check(length(sockets) == 3, 'parses ss process sockets');
check(sockets[0].processName == 'qbittorrent-nox',
	'associates qBittorrent process name');
check(sockets[1].local.port == 55555, 'parses inbound qB socket');

check(util.ip_in_cidr('192.168.200.47', '192.168.200.0/24'),
	'identifies VLAN200 IPv4');
check(!util.ip_in_cidr('192.168.1.20', '192.168.200.0/24'),
	'does not conflate LAN and VLAN200');
check(util.is_tailscale_destination('100.100.10.2'),
	'identifies Tailscale IPv4 range');

if (failures)
	exit(1);

print('All parser fixture tests passed.\n');
