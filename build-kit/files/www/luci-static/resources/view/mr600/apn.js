'use strict';
'require view';
'require form';
'require fs';

// Pick the APN from the modem's own operator catalog instead of typing it.
//
// The catalog is generated from the module's NetIspInfo.ini by
// tools/make-apn-mvno-table.py - it is the vendor's list of operators, which is what that file
// was built for (it carries Name/Package/Country for display). It is deliberately NOT the thing
// that derives the APN at boot: NetIspInfo.ini files several brands under one MCC/MNC with no
// discriminator, so it cannot be looked up automatically. lte-reset uses /etc/mr600-apn-table
// for the automatic case and /etc/mr600-apn-mvno-table for the brands the vendor does
// distinguish. This page is the human in the loop for the rest.
//
// The write path is LuCI's own form/uci plumbing, so it needs no custom RPC - only read access
// to the catalog, which is what the accompanying acl.d file grants.

return view.extend({
	load: function() {
		return L.resolveDefault(fs.read('/etc/mr600-apn-catalog'), '');
	},

	render: function(catalog) {
		var rows = [], seen = {};

		(catalog || '').split('\n').forEach(function(line) {
			if (!line || line.charAt(0) === '#')
				return;
			var f = line.split('\t');
			if (f.length < 3 || !f[0] || !f[1] || !f[2])
				return;
			// one option per APN: the catalog repeats an APN under several brand names
			if (seen[f[2]])
				return;
			seen[f[2]] = true;
			rows.push({ name: f[1], apn: f[2], country: f[5] || '' });
		});

		if (!rows.length)
			return E('div', { 'class': 'alert-message warning' }, [
				_('No operator catalog is present on this device.'),
				E('br'),
				_('Set the APN from the shell instead: uci set network.wwan0.apn=<apn>')
			]);

		rows.sort(function(a, b) {
			var ca = a.country || '\uffff', cb = b.country || '\uffff';
			return ca.localeCompare(cb) || a.name.localeCompare(b.name);
		});

		var m = new form.Map('network', _('Operator APN'),
			_('The APN the LTE modem attaches with. Changing it re-attaches the modem, which ' +
			  'takes about 40 seconds and briefly drops the link.'));

		var s = m.section(form.NamedSection, 'wwan0', 'interface');
		s.anonymous = true;
		s.addremove = false;

		var o = s.option(form.ListValue, 'apn', _('APN'));
		o.rmempty = false;
		rows.forEach(function(r) {
			o.value(r.apn, (r.country ? r.country + ' \u2014 ' : '') + r.name + '  (' + r.apn + ')');
		});
		o.description = _('%d operators, from the modem\'s own catalog. The value in use is the ' +
			'one already selected; an APN that is not listed can still be set from the shell.')
			.format(rows.length);

		return m.render();
	}
});
