'use strict';
'require baseclass';

/*
 * Canvas topology: devices (left) -> 分流 (middle) -> exits (right).
 *
 * Everything drawn here comes from setData(): line width follows real
 * bytes/s, particle density follows real packets/s. A link with zero
 * packets/s emits no particles, and nothing is ever randomised.
 * Exits and their colors are supplied by the caller (discovered on the router).
 */

var FIXED = { local: '本地', unknown: '未知', mixed: '混合' };
var FADE_SECONDS = 3;
var TRAVEL_SECONDS = 2.4;
var MAX_PARTICLES = 700;

function cssVar(element, name, fallback) {
	var value = getComputedStyle(element).getPropertyValue(name);
	return (value && value.trim()) || fallback;
}

function formatRate(value) {
	value = Number(value) || 0;
	if (value >= 1048576) return (value / 1048576).toFixed(1) + ' MB/s';
	if (value >= 1024) return (value / 1024).toFixed(value >= 10240 ? 0 : 1) + ' KB/s';
	return Math.round(value) + ' B/s';
}

function truncate(ctx, text, width) {
	text = String(text == null ? '' : text);
	if (ctx.measureText(text).width <= width)
		return text;
	while (text.length > 1 && ctx.measureText(text + '…').width > width)
		text = text.slice(0, -1);
	return text + '…';
}

function bezier(p0, p1, p2, p3, t) {
	var u = 1 - t;
	return {
		x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
		y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
	};
}

function widthFor(bps) {
	return Math.max(1.5, Math.min(10, 1.5 + Math.log10(1 + (bps || 0) / 1024) * 2.2));
}

/* Particles per second, driven only by the link's real packets/s. */
function spawnRate(pps) {
	return pps > 0 ? Math.min(14, Math.log2(1 + pps) * 1.4) : 0;
}

function Animator(canvas, options) {
	this.canvas = canvas;
	this.ctx = canvas.getContext('2d');
	this.options = options || {};
	this.devices = [];
	this.exits = [];
	this.links = {};
	this.particles = [];
	this.selected = null;
	this.selectedExit = null;
	this.focus = { column: 'devices', index: -1 };
	this.hover = null;
	this.paused = false;
	this.staticMode = false;
	this.stale = false;
	this.speed = 1;
	this.lastFrame = 0;
	this.layout = null;

	this.onResize = this.resize.bind(this);
	this.onPointerMove = this.pointerMove.bind(this);
	this.onPointerLeave = this.pointerLeave.bind(this);
	this.onPointerDown = this.pointerDown.bind(this);
	this.onKeyDown = this.keyDown.bind(this);
	this.tick = this.tick.bind(this);

	window.addEventListener('resize', this.onResize);
	canvas.addEventListener('pointermove', this.onPointerMove);
	canvas.addEventListener('pointerleave', this.onPointerLeave);
	canvas.addEventListener('pointerdown', this.onPointerDown);
	canvas.addEventListener('keydown', this.onKeyDown);

	this.resize();
	this.frame = window.requestAnimationFrame(this.tick);
}

Animator.prototype = {
	/*
	 * model.exits:   [{ id, label, color }] in display order
	 * model.devices: [{ key, name, path, mismatch }] already ordered
	 * model.links:   [{ device, path, bps, pps, flows, ratio }]
	 */
	setData: function(model) {
		var seen = {};
		var self = this;

		this.exits = model.exits || this.exits;
		this.devices = model.devices || [];
		this.stale = !!model.stale;

		(model.links || []).forEach(function(link) {
			var key = link.device + '|' + link.path;
			var current = self.links[key] || (self.links[key] = { alpha: 0, carry: 0 });

			seen[key] = true;
			current.device = link.device;
			current.path = link.path;
			current.bps = link.bps || 0;
			current.pps = link.pps || 0;
			current.flows = link.flows || 0;
			current.ratio = link.ratio;
			current.live = true;
		});

		Object.keys(this.links).forEach(function(key) {
			if (!seen[key])
				self.links[key].live = false;
		});

		this.resize();

		var count = this.focus.column == 'exits' ? this.layout.exitOrder.length : this.devices.length;
		if (this.focus.index >= count)
			this.focus.index = count - 1;
	},

	/* A selected device wins over a selected exit; clearing it restores the exit. */
	setSelected: function(key) {
		this.selected = key || null;
		this.draw();
	},

	setSelectedExit: function(path) {
		this.selectedExit = path || null;
		this.draw();
	},

	usesExit: function(deviceKey, path) {
		var link = this.links[deviceKey + '|' + path];
		return !!(link && link.live);
	},

	linkAlpha: function(link) {
		if (this.selected)
			return this.selected == link.device ? 1 : 0.12;
		if (this.selectedExit)
			return this.selectedExit == link.path ? 1 : 0.12;
		return 1;
	},

	deviceAlpha: function(key) {
		if (this.selected)
			return this.selected == key ? 1 : 0.12;
		if (this.selectedExit)
			return this.usesExit(key, this.selectedExit) ? 1 : 0.12;
		return 1;
	},

	exitAlpha: function(path) {
		if (this.selected)
			return this.usesExit(this.selected, path) ? 1 : 0.35;
		if (this.selectedExit)
			return this.selectedExit == path ? 1 : 0.35;
		return 1;
	},

	devicesOn: function(path) {
		var self = this;
		return this.devices.filter(function(device) { return self.usesExit(device.key, path); });
	},

	setPaused: function(paused) {
		this.paused = !!paused;
	},

	setSpeed: function(speed) {
		this.speed = speed || 1;
	},

	setStatic: function(enabled) {
		this.staticMode = !!enabled;
		if (enabled)
			this.particles = [];
		this.draw();
	},

	clear: function() {
		this.particles = [];
		this.links = {};
		this.devices = [];
		this.resize();
	},

	color: function(path) {
		var exit = this.exits.filter(function(e) { return e.id == path; })[0];
		if (exit)
			return exit.color;
		return cssVar(this.canvas, '--wfm-' + (FIXED[path] ? path : 'unknown'), '#8a94a6');
	},

	label: function(path) {
		var exit = this.exits.filter(function(e) { return e.id == path; })[0];
		return exit ? exit.label : (FIXED[path] || path);
	},

	/* All discovered exits, plus 本地 / 未知 only while some link uses them. */
	exitsInUse: function() {
		var self = this;
		var ids = this.exits.map(function(exit) { return exit.id; });

		[ 'local', 'unknown' ].forEach(function(path) {
			var used = Object.keys(self.links).some(function(key) { return self.links[key].path == path; });
			if (used)
				ids.push(path);
		});

		return ids;
	},

	resize: function() {
		var parent = this.canvas.parentNode;
		var width = Math.max(280, parent ? parent.clientWidth : 600);
		var narrow = width < 520;
		var rowHeight = narrow ? 30 : 36;
		var exits = this.exitsInUse();
		var rows = Math.max(this.devices.length, exits.length * 2, 6);
		var height = Math.max(narrow ? 280 : 380, rows * rowHeight + 48);
		var ratio = window.devicePixelRatio || 1;
		var leftLabel = Math.min(narrow ? 96 : 170, width * 0.3);
		var rightLabel = Math.min(narrow ? 70 : 130, width * 0.24);
		var deviceX = leftLabel + 10;
		var exitX = width - rightLabel - 10;
		var top = 24;
		var layout = {
			width: width,
			height: height,
			narrow: narrow,
			rowHeight: rowHeight,
			leftLabel: leftLabel,
			deviceX: deviceX,
			exitX: exitX,
			hub: { x: deviceX + (exitX - deviceX) * 0.55, y: height / 2 },
			devices: {},
			exits: {},
			exitOrder: exits
		};
		var deviceStep = (height - top * 2) / Math.max(1, this.devices.length);
		var exitSpan = Math.min(height - top * 2, Math.max(exits.length * 70, height * 0.55));
		var exitStep = exitSpan / Math.max(1, exits.length);

		this.devices.forEach(function(device, index) {
			layout.devices[device.key] = { x: deviceX, y: top + deviceStep * (index + 0.5) };
		});

		exits.forEach(function(path, index) {
			layout.exits[path] = { x: exitX, y: (height - exitSpan) / 2 + exitStep * (index + 0.5) };
		});

		this.layout = layout;
		this.canvas.style.height = height + 'px';
		this.canvas.width = Math.round(width * ratio);
		this.canvas.height = Math.round(height * ratio);
		this.ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
		this.draw();
	},

	/* Two cubic segments: device -> hub -> exit, offset for parallel paths. */
	geometry: function(link) {
		var layout = this.layout;
		var from = layout && layout.devices[link.device];
		var to = layout && layout.exits[link.path];

		if (!from || !to)
			return null;

		var order = layout.exitOrder.indexOf(link.path);
		var offset = (order - (layout.exitOrder.length - 1) / 2) * 2.5;
		var hub = { x: layout.hub.x, y: layout.hub.y + offset };
		var a = { x: from.x, y: from.y + offset };
		var midA = (a.x + hub.x) / 2;
		var midB = (hub.x + to.x) / 2;

		return [
			[ a, { x: midA, y: a.y }, { x: midA, y: hub.y }, hub ],
			[ hub, { x: midB, y: hub.y }, { x: midB, y: to.y }, to ]
		];
	},

	pointAt: function(geometry, t) {
		var segment = t < 0.5 ? geometry[0] : geometry[1];
		var local = t < 0.5 ? t * 2 : (t - 0.5) * 2;
		return bezier(segment[0], segment[1], segment[2], segment[3], local);
	},

	tick: function(timestamp) {
		var dt = this.lastFrame ? Math.min(0.1, (timestamp - this.lastFrame) / 1000) : 0;
		var animate = !this.paused && !this.staticMode && !this.stale;
		var self = this;
		var changed = false;

		this.lastFrame = timestamp;

		Object.keys(this.links).forEach(function(key) {
			var link = self.links[key];
			var target = link.live ? 1 : 0;

			if (self.paused)
				return;

			if (link.alpha != target) {
				var step = dt / (target ? 0.4 : FADE_SECONDS);
				link.alpha = target ? Math.min(1, link.alpha + step) : Math.max(0, link.alpha - step);
				changed = true;
			}

			if (!link.live && link.alpha <= 0) {
				delete self.links[key];
				return;
			}

			if (animate && link.live) {
				link.carry += spawnRate(link.pps) * self.speed * dt;
				while (link.carry >= 1 && self.particles.length < MAX_PARTICLES) {
					link.carry -= 1;
					self.particles.push({ key: key, t: 0 });
				}
				if (link.carry >= 1)
					link.carry = 0;
			}
		});

		if (animate) {
			this.particles = this.particles.filter(function(particle) {
				particle.t += dt * self.speed / TRAVEL_SECONDS;
				return particle.t < 1 && self.links[particle.key];
			});
			changed = changed || this.particles.length > 0;
		}

		if (changed)
			this.draw();

		this.frame = window.requestAnimationFrame(this.tick);
	},

	draw: function() {
		var ctx = this.ctx;
		var layout = this.layout;
		var canvas = this.canvas;
		var self = this;

		if (!layout)
			return;

		var text = getComputedStyle(canvas).color || '#333';
		var muted = cssVar(canvas, '--wfm-muted', '#8a94a6');
		var warn = cssVar(canvas, '--wfm-unknown', '#d49b00');
		var font = layout.narrow ? 11 : 12;
		/* Dimmed links first, so the highlighted ones are drawn on top. */
		var keys = Object.keys(this.links).sort(function(a, b) {
			return self.linkAlpha(self.links[a]) - self.linkAlpha(self.links[b]);
		});

		ctx.clearRect(0, 0, layout.width, layout.height);
		ctx.lineCap = 'round';
		ctx.font = font + 'px sans-serif';
		ctx.textBaseline = 'middle';

		keys.forEach(function(key) {
			var link = self.links[key];
			var geometry = self.geometry(link);

			if (!geometry)
				return;

			/* Dimmed lines go gray: many overlapping faint lines would add up to full color. */
			var emphasis = self.linkAlpha(link);
			ctx.globalAlpha = link.alpha * (emphasis < 1 ? 0.18 : 0.7);
			ctx.strokeStyle = emphasis < 1 ? muted : self.color(link.path);
			ctx.lineWidth = widthFor(link.bps);
			if (link.path == 'unknown')
				ctx.setLineDash([ 4, 4 ]);
			ctx.beginPath();
			geometry.forEach(function(segment) {
				ctx.moveTo(segment[0].x, segment[0].y);
				ctx.bezierCurveTo(segment[1].x, segment[1].y, segment[2].x, segment[2].y,
					segment[3].x, segment[3].y);
			});
			ctx.stroke();
			ctx.setLineDash([]);
		});

		this.particles.forEach(function(particle) {
			var link = self.links[particle.key];
			var geometry = link && self.linkAlpha(link) == 1 && self.geometry(link);

			if (!geometry)
				return;

			var point = self.pointAt(geometry, particle.t);
			ctx.globalAlpha = link.alpha;
			ctx.fillStyle = self.color(link.path);
			ctx.beginPath();
			ctx.arc(point.x, point.y, Math.min(3.5, 1.5 + widthFor(link.bps) / 4), 0, Math.PI * 2);
			ctx.fill();
		});

		this.devices.forEach(function(device, index) {
			var position = layout.devices[device.key];
			var name = truncate(ctx, device.name, layout.leftLabel - (device.mismatch ? 16 : 4));

			ctx.globalAlpha = self.deviceAlpha(device.key);
			ctx.fillStyle = self.color(device.path);
			ctx.beginPath();
			ctx.arc(position.x, position.y, 4, 0, Math.PI * 2);
			ctx.fill();

			ctx.fillStyle = text;
			ctx.textAlign = 'right';
			ctx.font = (self.selected == device.key ? 'bold ' : '') + font + 'px sans-serif';
			ctx.fillText(name, position.x - 10, position.y);

			if (device.mismatch) {
				ctx.fillStyle = warn;
				ctx.fillText('!', position.x - 16 - ctx.measureText(name).width, position.y);
			}

			if (self.focus.column == 'devices' && index == self.focus.index && document.activeElement == canvas) {
				ctx.strokeStyle = text;
				ctx.lineWidth = 1;
				ctx.strokeRect(2, position.y - layout.rowHeight / 2 + 2, position.x + 8, layout.rowHeight - 4);
			}
			ctx.font = font + 'px sans-serif';
		});

		ctx.globalAlpha = 1;
		ctx.fillStyle = muted;
		ctx.beginPath();
		ctx.arc(layout.hub.x, layout.hub.y, 5, 0, Math.PI * 2);
		ctx.fill();
		ctx.textAlign = 'center';
		ctx.fillText('分流', layout.hub.x, layout.hub.y - 16);

		var totals = {};
		Object.keys(this.links).forEach(function(key) {
			var link = self.links[key];
			if (link.live && (!self.selected || self.selected == link.device))
				totals[link.path] = (totals[link.path] || 0) + link.bps;
		});

		layout.exitOrder.forEach(function(path, index) {
			var position = layout.exits[path];
			var offset = layout.narrow ? 7 : 9;

			ctx.globalAlpha = self.exitAlpha(path);
			ctx.fillStyle = self.color(path);
			ctx.beginPath();
			ctx.arc(position.x, position.y, 6, 0, Math.PI * 2);
			ctx.fill();

			if (self.selectedExit == path) {
				ctx.strokeStyle = self.color(path);
				ctx.lineWidth = 2;
				ctx.beginPath();
				ctx.arc(position.x, position.y, 10, 0, Math.PI * 2);
				ctx.stroke();
			}

			if (self.focus.column == 'exits' && index == self.focus.index && document.activeElement == canvas) {
				ctx.strokeStyle = text;
				ctx.lineWidth = 1;
				ctx.strokeRect(position.x - 12, position.y - 18, layout.width - position.x + 10, 36);
			}

			ctx.fillStyle = self.color(path);
			ctx.textAlign = 'left';
			ctx.font = 'bold ' + font + 'px sans-serif';
			ctx.fillText(truncate(ctx, self.label(path), layout.width - position.x - 16), position.x + 12, position.y - offset);
			ctx.font = font + 'px sans-serif';
			ctx.fillStyle = muted;
			ctx.fillText(formatRate(totals[path]), position.x + 12, position.y + offset);
		});
		ctx.globalAlpha = 1;

		var overlay = this.stale ? '⚠ 数据已过期' : (!this.devices.length ? '暂无流量' : null);
		if (overlay) {
			ctx.fillStyle = this.stale ? warn : muted;
			ctx.textAlign = 'center';
			ctx.font = 'bold ' + (font + 2) + 'px sans-serif';
			ctx.fillText(overlay, layout.width / 2, 14);
		}

		if (this.hover)
			this.drawTooltip(this.hover);

		ctx.globalAlpha = 1;
	},

	drawTooltip: function(hover) {
		var ctx = this.ctx;
		var layout = this.layout;
		var width = ctx.measureText(hover.label).width + 16;
		var x = Math.min(layout.width - width - 4, Math.max(4, hover.x + 12));
		var y = Math.max(4, hover.y - 30);

		ctx.globalAlpha = 0.94;
		ctx.fillStyle = cssVar(this.canvas, '--wfm-tooltip-bg', '#222');
		ctx.fillRect(x, y, width, 22);
		ctx.globalAlpha = 1;
		ctx.fillStyle = cssVar(this.canvas, '--wfm-tooltip-fg', '#fff');
		ctx.textAlign = 'left';
		ctx.fillText(hover.label, x + 8, y + 11);
	},

	pointerPosition: function(event) {
		var rect = this.canvas.getBoundingClientRect();
		return { x: event.clientX - rect.left, y: event.clientY - rect.top };
	},

	/*
	 * Exit node or label -> exit. Left column -> device. Near a line: the
	 * device -> 分流 half selects the device, the 分流 -> exit half the exit.
	 */
	hitTest: function(point) {
		var layout = this.layout;
		var self = this;
		var best = null;

		if (!layout)
			return null;

		layout.exitOrder.forEach(function(path) {
			var position = layout.exits[path];
			if (point.x >= position.x - 14 && Math.abs(point.y - position.y) < 18)
				best = { type: 'exit', path: path };
		});

		if (best)
			return best;

		this.devices.forEach(function(device) {
			var position = layout.devices[device.key];
			if (point.x <= position.x + 10 && Math.abs(point.y - position.y) < layout.rowHeight / 2)
				best = { type: 'device', device: device };
		});

		if (best)
			return best;

		var bestDistance = 8;
		Object.keys(this.links).forEach(function(key) {
			var link = self.links[key];
			var geometry = link.live && self.geometry(link);

			if (!geometry)
				return;

			for (var step = 0; step <= 40; step++) {
				var t = step / 40;

				if (t < 0.5 && self.selected && self.selected != link.device)
					continue;

				var p = self.pointAt(geometry, t);
				var distance = Math.hypot(p.x - point.x, p.y - point.y);
				if (distance < bestDistance) {
					bestDistance = distance;
					best = t >= 0.5 ? { type: 'exit', path: link.path } : { type: 'link', link: link };
				}
			}
		});

		return best;
	},

	describe: function(hit) {
		if (!hit)
			return null;

		if (hit.type == 'device')
			return hit.device.name;

		if (hit.type == 'exit') {
			var count = this.devicesOn(hit.path).length;
			return this.label(hit.path) + ' · ' + count + ' 个来源' +
				(this.selectedExit == hit.path ? ' · 点击取消' : ' · 点击筛选');
		}

		var device = this.devices.filter(function(d) { return d.key == hit.link.device; })[0];
		return (device ? device.name : '') + ' → ' + this.label(hit.link.path) +
			' · ' + formatRate(hit.link.bps) +
			(hit.link.ratio != null && hit.link.ratio < 1 ? ' · ' + Math.round(hit.link.ratio * 100) + '%' : '');
	},

	pointerMove: function(event) {
		var point = this.pointerPosition(event);
		var hit = this.hitTest(point);
		var label = this.describe(hit);

		this.canvas.style.cursor = hit ? 'pointer' : 'default';
		this.hover = label ? { x: point.x, y: point.y, label: label } : null;
		this.draw();
	},

	pointerLeave: function() {
		this.hover = null;
		this.draw();
	},

	pointerDown: function(event) {
		var point = this.pointerPosition(event);
		var hit = this.hitTest(point);

		if (event.pointerType == 'touch') {
			var label = this.describe(hit);
			this.hover = label ? { x: point.x, y: point.y, label: label } : null;
		}

		if (!hit)
			this.clearOne();
		else if (hit.type == 'exit')
			this.selectExit(this.selectedExit == hit.path && !this.selected ? null : hit.path);
		else if (hit.type == 'device')
			this.select(this.selected == hit.device.key ? null : hit.device.key);
		else
			this.select(hit.link.device);
	},

	select: function(key) {
		this.selected = key;
		this.draw();
		if (this.options.onSelect)
			this.options.onSelect(key);
	},

	/* Picking an exit drops the device selection so the exit highlight shows. */
	selectExit: function(path) {
		this.selected = null;
		this.selectedExit = path;
		this.draw();
		if (this.options.onSelectExit)
			this.options.onSelectExit(path);
	},

	/* Background click / Esc: clear the device first, then the exit. */
	clearOne: function() {
		if (this.selected)
			this.select(null);
		else if (this.selectedExit)
			this.selectExit(null);
	},

	/* ↑↓ within a column, ←→ between devices and exits, Enter selects. */
	keyDown: function(event) {
		var focus = this.focus;
		var exits = this.layout ? this.layout.exitOrder : [];

		if (event.key == 'ArrowLeft' || event.key == 'ArrowRight') {
			event.preventDefault();
			focus.column = event.key == 'ArrowRight' ? 'exits' : 'devices';
			focus.index = 0;
		}
		else if (event.key == 'ArrowDown' || event.key == 'ArrowUp') {
			var count = focus.column == 'exits' ? exits.length : this.devices.length;
			if (!count)
				return;
			event.preventDefault();
			focus.index = (focus.index + (event.key == 'ArrowDown' ? 1 : count - 1)) % count;
		}
		else if ((event.key == 'Enter' || event.key == ' ') && focus.index >= 0) {
			event.preventDefault();
			if (focus.column == 'exits') {
				var path = exits[focus.index];
				this.selectExit(this.selectedExit == path && !this.selected ? null : path);
			}
			else if (this.devices[focus.index]) {
				var key = this.devices[focus.index].key;
				this.select(this.selected == key ? null : key);
			}
			return;
		}
		else if (event.key == 'Escape') {
			this.hover = null;
			this.clearOne();
			return;
		}
		else {
			return;
		}

		this.hover = this.focusHover();
		this.draw();
	},

	focusHover: function() {
		var focus = this.focus;
		var layout = this.layout;

		if (!layout || focus.index < 0)
			return null;

		if (focus.column == 'exits') {
			var path = layout.exitOrder[focus.index];
			var exit = path && layout.exits[path];
			return exit ? { x: exit.x - 140, y: exit.y, label: this.describe({ type: 'exit', path: path }) } : null;
		}

		var device = this.devices[focus.index];
		var position = device && layout.devices[device.key];
		return position ? { x: position.x, y: position.y, label: this.describe({ type: 'device', device: device }) } : null;
	}
};

return baseclass.extend({
	create: function(canvas, options) {
		return new Animator(canvas, options);
	},
	formatRate: formatRate
});
