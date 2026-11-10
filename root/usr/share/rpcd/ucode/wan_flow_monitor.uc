'use strict';

const collector = require('wan_flow_monitor.collector');

return {
	wan_flow_monitor: {
		overview: {
			call: function() {
				return collector.snapshot();
			}
		},

		history: {
			args: {
				since: 0,
				limit: 0
			},
			call: function(request) {
				return collector.history(
					request.args?.since,
					request.args?.limit
				);
			}
		},

		device_flows: {
			args: {
				device: ''
			},
			call: function(request) {
				return collector.device_flows(request.args?.device);
			}
		},

		health: {
			call: function() {
				return collector.health();
			}
		}
	}
};
