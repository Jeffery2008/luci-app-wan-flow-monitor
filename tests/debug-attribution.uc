'use strict';

const fs = require('fs');
const parsers = require('wan_flow_monitor.parsers');

let p = fs.popen('/usr/sbin/nft -j list table inet fw4', 'r');
let nft = parsers.parse_nft(json(p.read('all')));
p.close();

for (let rule in nft.rules)
	if (rule.comment)
		printf('rule chain=%s mark=%J comment=%s sets=%J\n',
			rule.chain, rule.mark, rule.comment, rule.setRefs);

printf('sets=%J\n', map(keys(nft.sets), (k) => `${k}:${length(nft.sets[k])}`));
