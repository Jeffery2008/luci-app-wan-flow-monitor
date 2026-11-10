'use strict';
'require view';
'require rpc';
'require poll';
'require wan-flow-monitor/topology as Topology';

/*
 * 多 WAN 分流监控 — read-only. Three questions, one screen:
 *   1. 各条线路现在跑多少？      (exit cards)
 *   2. 谁走了哪条线？            (topology + per-segment ratio bars)
 *   3. 和策略一致吗？            (device list: 策略 → 实际, ! = 不一致)
 * Exits, segments and rules are discovered on the router; nothing here names
 * a specific interface. All text is inserted as text nodes, never as HTML.
 */

var callOverview = rpc.declare({ object: 'wan_flow_monitor', method: 'overview', expect: { '': {} } });
var callHistory = rpc.declare({ object: 'wan_flow_monitor', method: 'history', params: [ 'since', 'limit' ], expect: { '': {} } });
var callDeviceFlows = rpc.declare({ object: 'wan_flow_monitor', method: 'device_flows', params: [ 'device' ], expect: { '': {} } });

/* Bump with every stylesheet change: uhttpd sends no Cache-Control for static files. */
var ASSET_VERSION = '1.1.0';
var POLL_SECONDS = 5;
var STALE_SECONDS = 15;
var SPEEDS = [ 0.5, 1, 2, 4 ];
/* Exit colors by discovery order (default route first). Purple, gray and yellow are reserved. */
var PALETTE = [ '#2f7de1', '#1f9d63', '#e8710a', '#d6336c', '#0d9488', '#0369a1' ];
var FIXED = { mixed: '混合', local: '本地', unknown: '未知' };
var CONFIDENCE = { high: '高', medium: '中', low: '低', unknown: '未知' };
var EVIDENCE = { conntrack: '连接跟踪 NAT 地址', mark: '防火墙标记 → 路由表', route: '路由表', none: '无' };
var KIND = { app: '路由器进程', router: '路由器', host: '未登记主机' };

/* ---------- tiny safe DOM helper (text nodes only) ---------- */

function h(tag, attrs, children) {
	var node = document.createElement(tag);

	Object.keys(attrs || {}).forEach(function(key) {
		var value = attrs[key];
		if (value == null || value === false)
			return;
		if (key.indexOf('on') == 0 && typeof value == 'function')
			node.addEventListener(key.slice(2), value);
		else
			node.setAttribute(key, value === true ? '' : String(value));
	});

	return append(node, children);
}

function append(node, children) {
	if (children == null)
		return node;
	if (!Array.isArray(children))
		children = [ children ];
	children.forEach(function(child) {
		if (child == null || child === false)
			return;
		node.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
	});
	return node;
}

function replace(node, children) {
	while (node.firstChild)
		node.removeChild(node.firstChild);
	return append(node, children);
}

/* ---------- formatting ---------- */

function rate(value) {
	return Topology.formatRate(value);
}

function bytes(value) {
	value = Number(value) || 0;
	if (value >= 1073741824) return (value / 1073741824).toFixed(1) + ' GB';
	if (value >= 1048576) return (value / 1048576).toFixed(1) + ' MB';
	if (value >= 1024) return (value / 1024).toFixed(0) + ' KB';
	return value + ' B';
}

function age(seconds) {
	if (seconds < 60) return Math.max(0, Math.round(seconds)) + ' 秒';
	return Math.floor(seconds / 60) + ' 分 ' + Math.round(seconds % 60) + ' 秒';
}

function now() {
	return Date.now() / 1000;
}

/* ---------- exits & paths ---------- */

function exitList(data) {
	return (data.exits || []).map(function(exit, index) {
		return { id: exit.id, label: exit.id, color: PALETTE[index % PALETTE.length], exit: exit };
	});
}

function Paths(exits) {
	this.exits = exits;
	this.byId = {};
	exits.forEach(function(exit) { this.byId[exit.id] = exit; }, this);
}

Paths.prototype = {
	isExit: function(path) { return !!this.byId[path]; },

	label: function(path) {
		return this.byId[path] ? this.byId[path].label : (FIXED[path] || path || '未知');
	},

	/* A colored dot + text; exits get their discovered color, the rest a CSS class. */
	chip: function(path) {
		var exit = this.byId[path];
		if (exit)
			return h('span', { 'class': 'wfm-chip', style: 'color:' + exit.color }, exit.label);
		path = FIXED[path] ? path : 'unknown';
		return h('span', { 'class': 'wfm-chip wfm-' + path }, FIXED[path]);
	},

	/* Configured side: one exit, several balanced exits, 本地 or 未知. */
	configuredChip: function(configured) {
		var self = this;
		if (configured && configured.path == 'balanced' && configured.exits.length)
			return h('span', { 'class': 'wfm-route' }, configured.exits.map(function(id, i) {
				return [ i ? '+' : null, self.chip(id) ];
			}).reduce(function(all, part) { return all.concat(part); }, []));
		return this.chip(configured ? configured.path : 'unknown');
	}
};

/* ---------- data shaping ---------- */

function buildRows(data) {
	return (data.devices || []).map(function(device) {
		return {
			key: device.key,
			kind: device.kind || 'device',
			name: device.name || device.hostname || device.ipv4 || device.mac || device.key,
			ip: device.ipv4 || '',
			mac: device.mac || '',
			segment: device.segment || 'other',
			configured: device.configured || { path: 'unknown', exits: [] },
			observed: device.observedPath || 'unknown',
			connections: device.activeConnections || 0,
			mismatch: device.mismatchConnections || 0,
			bps: device.bytesPerSecond || 0,
			pps: device.packetsPerSecond || 0,
			paths: device.paths || {}
		};
	});
}

function matchesSegment(row, segment) {
	return segment == 'all' || row.segment == segment;
}

function linksOf(row) {
	return Object.keys(row.paths).filter(function(path) {
		return row.paths[path].bps > 0;
	}).map(function(path) {
		var entry = row.paths[path];
		return { device: row.key, path: path, bps: entry.bps, pps: entry.pps, flows: entry.flows, ratio: row.bps ? entry.bps / row.bps : 1 };
	});
}

/* Canvas model: busiest devices plus one "其他 N 台" row. */
function canvasModel(rows, exits, limit, stale) {
	var active = rows.filter(function(row) { return row.bps > 0; });
	var shown = active.slice(0, limit);
	var rest = active.slice(limit);
	var devices = [];
	var links = [];

	shown.forEach(function(row) {
		devices.push({ key: row.key, name: row.name, path: row.observed, mismatch: row.mismatch > 0 });
		links = links.concat(linksOf(row));
	});

	if (rest.length) {
		var other = { key: '__other', bps: 0, paths: {} };
		rest.forEach(function(row) {
			Object.keys(row.paths).forEach(function(path) {
				var entry = other.paths[path] || (other.paths[path] = { bps: 0, pps: 0, flows: 0 });
				entry.bps += row.paths[path].bps;
				entry.pps += row.paths[path].pps;
				entry.flows += row.paths[path].flows;
				other.bps += row.paths[path].bps;
			});
		});
		devices.push({ key: '__other', name: '其他 ' + rest.length + ' 台', path: 'mixed', mismatch: false });
		links = links.concat(linksOf(other));
	}

	return { exits: exits, devices: devices, links: links, stale: stale };
}

/* Ring-buffer sample (one link per device × exit) -> rows for canvasModel. */
function replayRows(sample, segment, paths) {
	var rows = {};

	(sample.links || []).forEach(function(link) {
		if (!(link.bps > 0) || (segment != 'all' && link.segment != segment))
			return;
		var row = rows[link.device] || (rows[link.device] = { key: link.device, name: link.name, bps: 0, paths: {}, mismatch: 0 });
		row.paths[link.path] = { bps: link.bps, pps: link.pps, flows: link.flows };
		row.bps += link.bps;
		row.mismatch += link.mismatch || 0;
	});

	return Object.keys(rows).map(function(key) {
		var row = rows[key];
		var external = Object.keys(row.paths).filter(function(path) { return paths.isExit(path); });
		row.observed = external.length > 1 ? 'mixed' : (external[0] || Object.keys(row.paths)[0]);
		return row;
	}).sort(function(a, b) { return b.bps - a.bps; });
}

/* ---------- view ---------- */

return view.extend({
	load: function() {
		return callOverview().catch(function(error) {
			return { error: String(error) };
		});
	},

	render: function(initial) {
		var self = this;

		this.state = {
			data: null,
			rows: null,
			paths: new Paths([]),
			segment: 'all',
			filter: 'all',
			search: '',
			showIdle: false,
			selected: null,
			selectedFlows: null,
			paused: false,
			pendingData: null,
			speedIndex: 1,
			staticMode: window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches,
			replay: null,
			lastError: null,
			receivedAt: 0,
			tabsKey: ''
		};

		var n = this.nodes = {};

		n.status = h('span', { 'class': 'wfm-status', role: 'status' });
		n.errors = h('button', { 'class': 'wfm-errors', type: 'button', hidden: true, onclick: function() { self.showErrors(); } });
		n.exits = h('div', { 'class': 'wfm-wans' });
		n.bars = h('div', { 'class': 'wfm-bars' });
		n.canvas = h('canvas', { 'class': 'wfm-canvas', tabindex: '0', role: 'img', 'aria-label': '流量拓扑：左侧设备，中间分流，右侧出口。点击设备查看连接，点击出口筛选走该出口的设备。方向键移动，左右键切换设备和出口，回车选择。' });
		n.live = h('div', { 'class': 'wfm-sr', 'aria-live': 'polite' });
		n.pause = this.iconButton('⏸', '暂停', function() { self.togglePause(); });
		n.replay = this.iconButton('⟲', '回放最近 5 分钟', function() { self.toggleReplay(); });
		n.speed = this.iconButton('1×', '播放速度', function() { self.cycleSpeed(); });
		n.staticBtn = this.iconButton('◐', '静态模式（不显示粒子）', function() { self.toggleStatic(); });
		n.clear = this.iconButton('✕', '清空画面', function() { self.topology.clear(); self.applyToCanvas(); });
		n.segmentTabs = h('div', { 'class': 'wfm-seg', role: 'tablist', 'aria-label': '网段' });
		n.filterTabs = h('div', { 'class': 'wfm-seg', role: 'tablist', 'aria-label': '出口筛选' });
		n.legend = h('div', { 'class': 'wfm-legend', 'aria-hidden': 'true' });
		n.search = h('input', { type: 'search', 'class': 'wfm-search', placeholder: '搜索设备 / IP / MAC', 'aria-label': '搜索设备', oninput: function(ev) { self.state.search = ev.target.value.trim().toLowerCase(); self.renderList(); } });
		n.list = h('div', { 'class': 'wfm-list', role: 'list' });
		n.panel = h('aside', { 'class': 'wfm-panel', hidden: true, role: 'dialog', 'aria-label': '详情' });

		var root = h('div', { 'class': 'wfm notranslate', translate: 'no' }, [
			h('link', { rel: 'stylesheet', href: L.resource('wan-flow-monitor/wan-flow-monitor.css') + '?v=' + ASSET_VERSION }),
			h('div', { 'class': 'wfm-head' }, [ h('h2', {}, '多 WAN 分流'), h('div', { 'class': 'wfm-head-right' }, [ n.errors, n.status ]) ]),
			n.exits,
			h('section', { 'class': 'wfm-card' }, [
				h('div', { 'class': 'wfm-toolbar' }, [ n.segmentTabs, h('div', { 'class': 'wfm-icons' }, [ n.pause, n.replay, n.speed, n.staticBtn, n.clear ]) ]),
				h('div', { 'class': 'wfm-stage' }, n.canvas),
				n.legend,
				n.live
			]),
			n.bars,
			h('section', { 'class': 'wfm-card' }, [
				h('div', { 'class': 'wfm-toolbar' }, [ n.filterTabs, n.search ]),
				h('div', { 'class': 'wfm-row wfm-row-head', 'aria-hidden': 'true' }, [ h('span', {}, '设备'), h('span', {}, '策略 → 实际'), h('span', {}, '速率') ]),
				n.list
			]),
			n.panel
		]);

		document.addEventListener('keydown', function(ev) {
			if (ev.key == 'Escape' && !n.panel.hidden)
				self.closePanel();
		});

		window.requestAnimationFrame(function() {
			self.topology = Topology.create(n.canvas, {
				onSelect: function(key) { self.select(key == '__other' ? null : key, true); },
				onSelectExit: function(path) { self.selectExit(path, true); }
			});
			self.topology.setStatic(self.state.staticMode);
			self.syncButtons();
			self.ingest(initial);
		});

		poll.add(function() {
			return callOverview().then(function(data) { self.ingest(data); }).catch(function(error) {
				self.state.lastError = String(error);
				self.renderStatus();
			});
		}, POLL_SECONDS);

		window.setInterval(function() { self.renderStatus(); }, 1000);

		return root;
	},

	/* ---------- controls ---------- */

	iconButton: function(icon, label, handler) {
		return h('button', { type: 'button', 'class': 'wfm-icon', title: label, 'aria-label': label, onclick: handler }, icon);
	},

	/* Rebuild a segmented control; options: [[value, label, node?]] */
	fillTabs: function(group, options, stateKey, onChange) {
		var self = this;

		if (!options.some(function(option) { return option[0] == self.state[stateKey]; }))
			this.state[stateKey] = 'all';

		replace(group, options.map(function(option) {
			return h('button', {
				type: 'button',
				role: 'tab',
				'data-value': option[0],
				'aria-selected': self.state[stateKey] == option[0] ? 'true' : 'false',
				onclick: function() {
					self.state[stateKey] = option[0];
					self.markTab(group, option[0]);
					onChange();
				}
			}, option[2] || option[1]);
		}));
	},

	markTab: function(group, value) {
		Array.prototype.forEach.call(group.children, function(button) {
			button.setAttribute('aria-selected', button.getAttribute('data-value') == value ? 'true' : 'false');
		});
	},

	renderTabs: function() {
		var self = this;
		var s = this.state;
		var segments = (s.data.segments || []).filter(function(segment) {
			return segment.kind == 'segment' || segment.activeDevices > 0;
		});
		var exits = s.paths.exits;
		var key = segments.map(function(x) { return x.id; }).join(',') + '|' + exits.map(function(x) { return x.id; }).join(',');

		if (key == s.tabsKey)
			return;

		s.tabsKey = key;

		this.fillTabs(this.nodes.segmentTabs,
			[ [ 'all', '全部' ] ].concat(segments.map(function(segment) { return [ segment.id, segment.name ]; })),
			'segment', function() { self.applyToCanvas(); self.renderList(); });

		this.fillTabs(this.nodes.filterTabs,
			[ [ 'all', '全部' ] ]
				.concat(exits.map(function(exit) { return [ exit.id, exit.label, s.paths.chip(exit.id) ]; }))
				.concat([ [ 'mismatch', '! 不一致' ] ]),
			'filter', function() { self.selectExit(s.paths.isExit(s.filter) ? s.filter : null, false, true); });

		replace(this.nodes.legend, exits.map(function(exit) { return s.paths.chip(exit.id); }).concat([
			s.paths.chip('mixed'), s.paths.chip('local'), s.paths.chip('unknown'),
			h('span', { 'class': 'wfm-legend-note' }, [ h('b', { 'class': 'wfm-warn' }, '!'), ' 与策略不一致' ])
		]));
	},

	syncButtons: function() {
		var s = this.state;
		var n = this.nodes;
		var set = function(button, icon, label) {
			button.textContent = icon;
			button.title = label;
			button.setAttribute('aria-label', label);
		};

		set(n.pause, s.paused ? '▶' : '⏸', s.paused ? '继续' : '暂停');
		set(n.replay, s.replay ? '■' : '⟲', s.replay ? '退出回放' : '回放最近 5 分钟');
		n.speed.textContent = SPEEDS[s.speedIndex] + '×';
		n.staticBtn.setAttribute('aria-pressed', s.staticMode ? 'true' : 'false');
	},

	togglePause: function() {
		var s = this.state;
		s.paused = !s.paused;
		this.topology.setPaused(s.paused);
		if (!s.paused && s.pendingData) {
			var data = s.pendingData;
			s.pendingData = null;
			this.ingest(data);
		}
		this.syncButtons();
		this.renderStatus();
	},

	cycleSpeed: function() {
		this.state.speedIndex = (this.state.speedIndex + 1) % SPEEDS.length;
		this.topology.setSpeed(SPEEDS[this.state.speedIndex]);
		this.syncButtons();
	},

	toggleStatic: function() {
		this.state.staticMode = !this.state.staticMode;
		this.topology.setStatic(this.state.staticMode);
		this.syncButtons();
	},

	toggleReplay: function() {
		var self = this;
		var s = this.state;

		if (s.replay) {
			window.clearTimeout(s.replay.timer);
			s.replay = null;
			this.syncButtons();
			this.applyToCanvas();
			this.renderStatus();
			return;
		}

		callHistory(0, 120).then(function(result) {
			var samples = (result && result.samples) || [];
			if (samples.length < 2) {
				self.announce('历史数据不足，稍后再试');
				return;
			}
			s.replay = { samples: samples, index: 0, timer: null };
			self.syncButtons();
			self.playFrame();
		});
	},

	playFrame: function() {
		var self = this;
		var s = this.state;
		var replay = s.replay;

		if (!replay)
			return;

		if (replay.index >= replay.samples.length) {
			this.toggleReplay();
			return;
		}

		var sample = replay.samples[replay.index];
		var next = replay.samples[replay.index + 1];

		this.topology.setData(canvasModel(replayRows(sample, s.segment, s.paths), s.paths.exits, this.deviceLimit(), false));
		this.renderStatus();

		var gap = next ? Math.max(1, next.timestamp - sample.timestamp) : POLL_SECONDS;
		replay.index++;
		replay.timer = window.setTimeout(function() {
			if (s.paused) {
				replay.index--;
				replay.timer = window.setTimeout(function() { self.playFrame(); }, 500);
				return;
			}
			self.playFrame();
		}, gap * 1000 / SPEEDS[s.speedIndex]);
	},

	deviceLimit: function() {
		return this.nodes.canvas.clientWidth < 520 ? 10 : 16;
	},

	/* ---------- data ---------- */

	ingest: function(data) {
		var s = this.state;

		if (!data || data.error) {
			s.lastError = data ? data.error : '无响应';
			this.renderStatus();
			return;
		}

		if (s.paused) {
			s.pendingData = data;
			this.renderStatus();
			return;
		}

		s.lastError = null;
		s.data = data;
		s.receivedAt = now();
		s.paths = new Paths(exitList(data));
		s.rows = buildRows(data);

		this.renderTabs();
		this.renderStatus();
		this.renderExits();
		this.renderBars();
		this.applyToCanvas();
		this.renderList();

		if (s.selected)
			this.loadSelectedFlows();
	},

	/* Router clock at fetch time plus local elapsed time: immune to clock skew. */
	dataAge: function() {
		var s = this.state;
		if (!s.data)
			return Infinity;
		return Math.max(0, (s.data.generatedAt || 0) - (s.data.dataTimestamp || 0)) + (now() - s.receivedAt);
	},

	isStale: function() {
		var data = this.state.data;
		return !data || !data.dataTimestamp || this.dataAge() > STALE_SECONDS;
	},

	applyToCanvas: function() {
		var s = this.state;
		if (!this.topology || !s.rows || s.replay)
			return;
		var rows = s.rows.filter(function(row) { return matchesSegment(row, s.segment); });
		this.topology.setData(canvasModel(rows, s.paths.exits, this.deviceLimit(), this.isStale()));
		this.topology.setSelected(s.selected);
		this.topology.setSelectedExit(s.paths.isExit(s.filter) ? s.filter : null);
	},

	/* ---------- rendering ---------- */

	renderStatus: function() {
		var s = this.state;
		var n = this.nodes;
		var data = s.data;
		var text, tone;

		if (s.replay) {
			var samples = s.replay.samples;
			var sample = samples[Math.max(0, s.replay.index - 1)];
			text = '⟲ 回放 −' + age(sample ? samples[samples.length - 1].timestamp - sample.timestamp : 0);
			tone = 'replay';
		}
		else if (s.paused) {
			text = '⏸ 已暂停';
			tone = 'paused';
		}
		else if (!data) {
			text = s.lastError ? '⚠ 无法读取' : '加载中…';
			tone = 'stale';
		}
		else {
			var source = data.dataSource == 'router' && data.productionData ? '' : '示例数据 · ';
			text = this.isStale() ? '⚠ 已过期 · ' + age(this.dataAge()) : '● ' + source + age(this.dataAge()) + '前';
			tone = this.isStale() ? 'stale' : 'live';
		}

		n.status.textContent = text;
		n.status.className = 'wfm-status wfm-status-' + tone;

		if (this.topology && !s.replay && s.rows && this.isStale() != this.topology.stale)
			this.applyToCanvas();

		var count = ((data && data.errors) || []).length + (s.lastError ? 1 : 0);
		n.errors.hidden = !count;
		n.errors.textContent = '⚠ ' + count;
		n.errors.setAttribute('aria-label', count + ' 个数据源错误');
	},

	renderExits: function() {
		var s = this.state;

		if (!s.paths.exits.length) {
			replace(this.nodes.exits, h('div', { 'class': 'wfm-wan wfm-muted' }, '没有发现 WAN 出口'));
			return;
		}

		replace(this.nodes.exits, s.paths.exits.map(function(item) {
			var exit = item.exit;
			var r = exit.rates;
			var ip = (exit.ipv4[0] && exit.ipv4[0].address) || (exit.ipv6[0] && exit.ipv6[0].address) || '';
			var healthy = exit.up && (!exit.health || exit.health.status == 'healthy');

			return h('div', { 'class': 'wfm-wan', style: 'border-top-color:' + item.color }, [
				h('div', { 'class': 'wfm-wan-title' }, [
					s.paths.chip(exit.id),
					exit.isDefault4 || exit.isDefault6 ? h('span', { 'class': 'wfm-tag' }, '默认') : null,
					healthy ? null : h('span', { 'class': 'wfm-tag wfm-bad' }, exit.up ? '异常' : '离线')
				]),
				h('div', { 'class': 'wfm-wan-rate' }, r ? [ '↓ ', rate(r.rx), h('br'), '↑ ', rate(r.tx) ] : [ '↓ …', h('br'), '↑ …' ]),
				h('div', { 'class': 'wfm-muted' }, [ exit.device, ip ? ' · ' + ip : '' ])
			]);
		}));
	},

	renderBars: function() {
		var s = this.state;
		var paths = s.paths;
		/* LAN segments, then router processes that use a WAN (e.g. a BT client). */
		var items = (s.data.segments || []).filter(function(segment) {
			return segment.kind == 'segment';
		}).map(function(segment) {
			return { name: segment.name, traffic: segment.traffic || {} };
		});

		s.rows.filter(function(row) {
			return row.kind == 'app' && paths.exits.some(function(exit) { return (row.paths[exit.id] || {}).bps > 0; });
		}).slice(0, 3).forEach(function(row) {
			var traffic = {};
			Object.keys(row.paths).forEach(function(path) { traffic[path] = row.paths[path].bps; });
			items.push({ name: row.name, traffic: traffic });
		});

		replace(this.nodes.bars, items.map(function(item) {
			var total = 0;
			paths.exits.forEach(function(exit) { total += item.traffic[exit.id] || 0; });

			var parts = paths.exits.map(function(exit) {
				return { exit: exit, share: total ? (item.traffic[exit.id] || 0) / total : 0 };
			}).filter(function(part) { return part.share > 0; });
			var text = parts.map(function(part) {
				var percent = part.share * 100;
				return part.exit.label + ' ' + (percent < 1 ? '<1' : Math.round(percent)) + '%';
			}).join(' · ');

			return h('div', { 'class': 'wfm-bar-item' }, [
				h('span', { 'class': 'wfm-bar-name', title: item.name }, item.name),
				h('div', { 'class': 'wfm-bar', role: 'img', 'aria-label': total ? item.name + ' ' + text : item.name + ' 无外网流量' },
					parts.map(function(part) {
						return h('i', { style: 'width:' + (part.share * 100).toFixed(1) + '%;background:' + part.exit.color });
					})),
				h('span', { 'class': 'wfm-bar-text' }, total ? text : '—')
			]);
		}));
	},

	visibleRows: function() {
		var s = this.state;
		var query = s.search;

		var rows = (s.rows || []).filter(function(row) {
			if (!matchesSegment(row, s.segment))
				return false;
			if (query && (row.name + ' ' + row.ip + ' ' + row.mac + ' ' + row.key).toLowerCase().indexOf(query) < 0)
				return false;
			if (s.filter == 'mismatch')
				return row.mismatch > 0;
			/* An exit filter means: has connections actually leaving through it. */
			if (s.filter != 'all')
				return !!row.paths[s.filter];
			return true;
		});

		if (s.paths.isExit(s.filter))
			rows.sort(function(a, b) { return b.paths[s.filter].bps - a.paths[s.filter].bps; });

		return rows;
	},

	renderList: function() {
		var self = this;
		var s = this.state;
		var rows = this.visibleRows();
		var active = rows.filter(function(row) { return row.connections > 0 || row.key == s.selected; });
		var idle = rows.filter(function(row) { return row.connections == 0 && row.key != s.selected; });
		var shown = s.showIdle ? active.concat(idle) : active;
		var children = shown.map(function(row) { return self.renderRow(row); });

		if (!shown.length)
			children.push(h('div', { 'class': 'wfm-empty' }, '没有匹配的设备'));

		if (idle.length)
			children.push(h('button', { type: 'button', 'class': 'wfm-more', onclick: function() { s.showIdle = !s.showIdle; self.renderList(); } },
				s.showIdle ? '隐藏空闲' : '+ ' + idle.length + ' 台空闲'));

		replace(this.nodes.list, children);
	},

	segmentName: function(id) {
		var segment = ((this.state.data && this.state.data.segments) || []).filter(function(x) { return x.id == id; })[0];
		return segment ? segment.name : '';
	},

	renderRow: function(row) {
		var self = this;
		var s = this.state;
		var selected = s.selected == row.key;
		var idle = row.connections == 0;
		var tag = KIND[row.kind] || (s.segment == 'all' ? this.segmentName(row.segment) : '');

		var line = h('button', {
			type: 'button',
			'class': 'wfm-row' + (selected ? ' is-selected' : '') + (idle ? ' is-idle' : ''),
			'aria-expanded': selected ? 'true' : 'false',
			onclick: function() { self.select(selected ? null : row.key, false); }
		}, [
			h('span', { 'class': 'wfm-name' }, [
				row.mismatch ? h('b', { 'class': 'wfm-warn', title: row.mismatch + ' 条连接与策略不一致' }, '! ') : null,
				h('span', {}, row.name),
				tag ? h('small', { 'class': 'wfm-muted' }, ' ' + tag) : null
			]),
			h('span', { 'class': 'wfm-route' }, [
				s.paths.configuredChip(row.configured),
				h('span', { 'class': 'wfm-arrow' }, '→'),
				idle ? h('span', { 'class': 'wfm-muted' }, '—') : s.paths.chip(row.observed)
			]),
			h('span', { 'class': 'wfm-rate' }, row.bps ? rate(row.bps) : '')
		]);

		var item = h('div', { role: 'listitem', 'class': 'wfm-item' }, line);

		if (selected)
			append(item, this.renderFlows());

		return item;
	},

	renderFlows: function() {
		var self = this;
		var s = this.state;
		var result = s.selectedFlows;

		if (!result)
			return h('div', { 'class': 'wfm-flows wfm-muted' }, '读取连接…');

		var flows = result.flows || [];
		if (!flows.length)
			return h('div', { 'class': 'wfm-flows wfm-muted' }, '当前没有连接');

		var list = flows.slice(0, 30).map(function(flow) {
			var target = flow.aggregated ? flow.aggregatedFlowCount + ' 条小连接' :
				(flow.destIp || '') + (flow.destPort ? ':' + flow.destPort : '');

			return h('button', { type: 'button', 'class': 'wfm-flow', onclick: function() { self.openPanel(flow); } }, [
				h('span', { 'class': 'wfm-flow-proto' }, String(flow.protocol || '').toUpperCase()),
				h('span', { 'class': 'wfm-flow-target' }, target),
				h('span', { 'class': 'wfm-route' }, [ flow.mismatch ? h('b', { 'class': 'wfm-warn' }, '! ') : null, s.paths.chip(flow.observedPath) ]),
				h('span', { 'class': 'wfm-rate' }, flow.bytesPerSecond ? rate(flow.bytesPerSecond) : '')
			]);
		});

		if (result.total > 30)
			list.push(h('div', { 'class': 'wfm-muted wfm-flow-more' }, '另有 ' + (result.total - 30) + ' 条'));

		return h('div', { 'class': 'wfm-flows' }, list);
	},

	/*
	 * Exit filter shared by the canvas (click an exit) and the list tabs:
	 * highlights device -> 分流 -> exit paths and lists those devices.
	 */
	selectExit: function(path, fromCanvas, fromTab) {
		var s = this.state;

		if (!fromTab) {
			s.filter = path || (s.paths.isExit(s.filter) ? 'all' : s.filter);
			this.markTab(this.nodes.filterTabs, s.filter);
		}

		s.selected = null;
		s.selectedFlows = null;

		if (this.topology && !fromCanvas) {
			this.topology.setSelected(null);
			this.topology.setSelectedExit(path);
		}

		if (path) {
			var count = (s.rows || []).filter(function(row) {
				return matchesSegment(row, s.segment) && row.paths[path];
			}).length;
			this.announce('已筛选 ' + s.paths.label(path) + '：' + count + ' 个来源');
		}
		else {
			this.announce('已取消出口筛选');
		}

		this.renderList();
	},

	select: function(key, fromCanvas) {
		var s = this.state;
		var row = (s.rows || []).filter(function(r) { return r.key == key; })[0];

		/* A device outside the current exit filter would vanish from the list. */
		if (row && s.paths.isExit(s.filter) && !row.paths[s.filter]) {
			s.filter = 'all';
			this.markTab(this.nodes.filterTabs, 'all');
			if (this.topology)
				this.topology.setSelectedExit(null);
		}

		s.selected = key;
		s.selectedFlows = null;

		if (this.topology && !fromCanvas)
			this.topology.setSelected(key);

		if (row) {
			var parts = Object.keys(row.paths).filter(function(path) { return row.paths[path].bps > 0; })
				.map(function(path) { return s.paths.label(path) + ' ' + rate(row.paths[path].bps); });
			this.announce('已选中 ' + row.name + (parts.length ? '：' + parts.join('，') : ''));
			this.loadSelectedFlows();
		}
		else if (!key) {
			this.announce('已取消选择');
		}

		this.renderList();
	},

	loadSelectedFlows: function() {
		var self = this;
		var key = this.state.selected;

		callDeviceFlows(key).then(function(result) {
			if (self.state.selected != key)
				return;
			self.state.selectedFlows = result || { flows: [] };
			self.renderList();
		});
	},

	announce: function(text) {
		this.nodes.live.textContent = text;
	},

	/* ---------- detail panel ---------- */

	panelHead: function(title) {
		var self = this;
		return h('div', { 'class': 'wfm-panel-head' }, [
			h('strong', {}, title),
			h('button', { type: 'button', 'class': 'wfm-icon', 'aria-label': '关闭', title: '关闭', onclick: function() { self.closePanel(); } }, '✕')
		]);
	},

	openPanel: function(flow) {
		var s = this.state;
		var panel = this.nodes.panel;
		var row = function(label, value) {
			return value == null || value === '' ? null : [ h('dt', {}, label), h('dd', {}, value) ];
		};
		var target = flow.aggregated ? flow.aggregatedFlowCount + ' 条连接（已合并）' :
			(flow.destIp || '') + (flow.destPort ? ':' + flow.destPort : '');
		var configured = { path: flow.configuredPath, exits: flow.configuredExits || [] };
		var rule = flow.ruleName ? flow.ruleName + (flow.ruleProvider ? '（' + flow.ruleProvider + '）' : '') : '默认路由';
		var list = h('dl', {});

		[
			row('设备', flow.device && flow.device.name),
			row('目的', target),
			row('协议', String(flow.protocol || '').toUpperCase() + ' · ' + (flow.family == 'ipv6' ? 'IPv6' : 'IPv4') + (flow.direction == 'inbound' ? ' · 入站' : '')),
			row('策略', [ s.paths.configuredChip(configured), ' ', rule ]),
			row('实际', [ s.paths.chip(flow.observedPath), flow.mismatch ? h('b', { 'class': 'wfm-warn' }, ' ! 与策略不一致') : null ]),
			row('原因', flow.ruleReason),
			row('依据', (EVIDENCE[flow.evidence] || flow.evidence || '') + ' · 可信度' + (CONFIDENCE[flow.confidence] || '未知')),
			row('出口地址', flow.natSource),
			row('路由表', flow.routeTable),
			row('标记', flow.firewallMark ? '0x' + Number(flow.firewallMark).toString(16) : '无'),
			row('速率', rate(flow.bytesPerSecond) + ' · ' + Math.round(flow.packetsPerSecond || 0) + ' 包/秒'),
			row('累计', bytes(flow.totalBytes)),
			row('限制', (flow.limitations || []).join('；'))
		].forEach(function(item) { if (item) append(list, item); });

		replace(panel, [ this.panelHead('连接详情'), list ]);
		panel.hidden = false;
		panel.querySelector('button').focus();
	},

	closePanel: function() {
		this.nodes.panel.hidden = true;
	},

	showErrors: function() {
		var s = this.state;
		var errors = ((s.data && s.data.errors) || []).slice();

		if (s.lastError)
			errors.push({ source: '请求', message: s.lastError });

		replace(this.nodes.panel, [
			this.panelHead('数据源错误'),
			h('p', { 'class': 'wfm-muted' }, '页面保留上一次成功的数据。'),
			h('dl', {}, errors.map(function(error) {
				return [ h('dt', {}, error.source || '?'), h('dd', {}, error.message || error.code || '') ];
			}).reduce(function(all, pair) { return all.concat(pair); }, []))
		]);

		this.nodes.panel.hidden = false;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
