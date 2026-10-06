/**
 * Database health panel: size, object counts, connection pool, per-table bloat
 * and index usage.
 *
 * The numbers come from PostgreSQL's statistics views, so row counts are the
 * planner's estimates rather than exact counts. That is stated on the panel
 * rather than left for the reader to assume, because a health screen that
 * quietly rounds is worse than one that says it rounds.
 */
function renderDatabase(data) {
  var conn = data.connections;
  var obj = data.objects;

  var cards = [
    { label: 'Database size', value: bytes(data.database.sizeBytes),
      sub: data.database.name + ' · PostgreSQL ' + data.database.serverVersion },
    { label: 'Connections', value: num(conn.total) + ' / ' + num(conn.max),
      sub: num(conn.used) + ' active, ' + num(conn.idle) + ' idle' },
    { label: 'Tables', value: num(obj.tables),
      sub: num(obj.indexes) + ' indexes' },
    { label: 'Estimated rows', value: num(obj.liveTuples),
      sub: num(obj.deadTuples) + ' dead (bloat)' },
    { label: 'Server uptime', value: uptime(data.database.serverUptimeSeconds),
      sub: 'whole server, not this connection' },
    { label: 'Unused indexes', value: num(data.indexes.filter(function (i) { return i.unused; }).length),
      sub: data.indexes.length + ' non-unique indexes checked' }
  ];

  var html = '<div class="cards">' + cards.map(function (c) {
    return '<div class="card"><div class="label">' + esc(c.label) + '</div>' +
      '<div class="value">' + esc(c.value) + '</div>' +
      '<div class="sub">' + esc(c.sub) + '</div></div>';
  }).join('') + '</div>';

  // A pool near its ceiling is the failure this page exists to catch, so it is
  // called out rather than left as one number among many.
  var poolPct = Math.round(conn.utilisation * 100);
  var poolClass = conn.utilisation > 0.8 ? 'red' : (conn.utilisation > 0.5 ? 'yellow' : 'green');
  html += '<div class="box"><h3>Connection pool</h3>' +
    '<div class="bars"><div class="bar-row">' +
    '<div>' + num(conn.total) + ' of ' + num(conn.max) + '</div>' +
    '<div class="bar-track"><div class="bar-fill' +
    (poolClass === 'green' ? '' : (poolClass === 'blue' ? ' blue' : '')) +
    '" style="width:' + Math.max(1, Math.min(100, poolPct)) + '%;' +
    (poolClass === 'red' ? 'background:var(--red)' : (poolClass === 'yellow' ? 'background:var(--yellow)' : '')) +
    '"></div></div>' +
    '<div class="bar-val">' + poolPct + '%</div>' +
    '</div></div>' +
    '<div class="legend"><span>Share of <code>max_connections</code> in use. ' +
    'Above 80% new requests will start queueing.</span></div></div>';

  html += '<div class="box"><h3>Largest tables</h3>' +
    barList(data.growth.map(function (g) { return { label: g.name, value: g.totalBytes }; }),
      { blue: true }) +
    '<div class="legend"><span>Heap plus indexes. These do not sum to the database ' +
    'size, which also counts WAL and catalog overhead.</span></div></div>';

  html += '<div class="box"><h3>Tables</h3><div class="table-wrap"><table><thead><tr>' +
    '<th>Table</th><th class="num">Rows</th><th class="num">Size</th>' +
    '<th class="num">Index share</th><th class="num">Dead rows</th>' +
    '<th class="num">Seq scans</th><th class="num">Index scans</th>' +
    '<th>Last vacuum</th></tr></thead><tbody>' +
    data.tables.map(function (t) {
      var dead = t.deadTuples > 0 ? ' style="color:var(--red)"' : '';
      return '<tr><td>' + esc(t.name) + '</td>' +
        '<td class="num">' + num(t.liveTuples) + '</td>' +
        '<td class="num">' + bytes(t.totalBytes) + '</td>' +
        '<td class="num">' + pct(t.indexBytes, t.totalBytes) + '</td>' +
        '<td class="num"' + dead + '>' + num(t.deadTuples) + '</td>' +
        '<td class="num">' + num(t.seqScans) + '</td>' +
        '<td class="num">' + num(t.idxScans) + '</td>' +
        '<td>' + esc(t.lastVacuum ? shortDate(t.lastVacuum) : 'never') + '</td></tr>';
    }).join('') +
    '</tbody></table></div></div>';

  html += '<div class="box"><h3>Indexes</h3>' +
    (data.indexes.length === 0
      ? emptyState('No non-unique indexes exist in this database. Unique and primary ' +
          'indexes are excluded: dropping one changes what the database accepts.')
      : '<div class="table-wrap"><table><thead><tr><th>Index</th><th>Table</th>' +
        '<th class="num">Size</th><th class="num">Times used</th></tr></thead><tbody>' +
        data.indexes.map(function (i) {
          return '<tr><td>' + esc(i.name) + '</td><td>' + esc(i.table) + '</td>' +
            '<td class="num">' + bytes(i.sizeBytes) + '</td>' +
            '<td class="num">' + (i.unused
              ? '<span class="tag red">never used</span>'
              : num(i.idxScans)) + '</td></tr>';
        }).join('') + '</tbody></table></div>') +
    '</div>';

  html += '<div class="box"><p class="hint" style="margin:0">' +
    'Row counts are the planner\'s estimates from PostgreSQL statistics, not exact ' +
    'counts, so they can lag a bulk load until the next ANALYZE. Slowest-query ' +
    'tracking needs the pg_stat_statements extension, which is not installed here.' +
    '</p></div>';

  render('database', html);
}

/** Bytes as a human-readable size, since these span kilobytes to gigabytes. */
function bytes(n) {
  n = Number(n || 0);
  var units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  while (n >= 1024 && i < units.length - 1) { n = n / 1024; i++; }
  return (i === 0 ? n : n.toFixed(1)) + ' ' + units[i];
}

function uptime(seconds) {
  var s = Number(seconds || 0);
  if (s <= 0) return '—';
  var d = Math.floor(s / 86400);
  var h = Math.floor((s % 86400) / 3600);
  var m = Math.floor((s % 3600) / 60);
  if (d > 0) return d + 'd ' + h + 'h';
  if (h > 0) return h + 'h ' + m + 'm';
  return m + 'm';
}
/*
/**
 * Administrative console: stops, routes, vehicles, fare rules and staff.
 *
 * Three behaviours here are not decoration and must not be "simplified" later:
 *
 *  - Fare rules have no edit affordance at all, only "New version" and
 *    "Activate". An editable fare form would let someone change a price that past
 *    tickets are priced against, which is the exact thing invariant I3 exists to
 *    prevent.
 *  - Every save re-reads from the server. The list is a cache of the last
 *    response, not a source of truth, so a rejected write cannot leave the screen
 *    showing an edit that never happened.
 *  - Destructive controls are toggles (activate / deactivate), never deletes.
 *    These records are referenced by trips and tickets that must stay readable, so
 *    nothing here can remove one.
 */
var ADMIN_RESOURCES = {
  stops: {
    label: 'Stops',
    endpoint: '/admin/stops',
    needs: 'canManage',
    columns: function (s) {
      return [
        { t: s.code }, { t: s.name }, { t: s.nameAm || '—' },
        { t: s.zone || '—', n: 1 },
        { t: s.latitude.toFixed(5) + ', ' + s.longitude.toFixed(5), n: 1 },
        { t: s.hasShelter ? 'yes' : 'no', n: 1 },
        { t: s.isActive ? statusTag('ACTIVE') : statusTag('SUSPENDED') }
      ];
    },
    fields: [
      { k: 'code', label: 'Code', required: true },
      { k: 'name', label: 'Name', required: true },
      { k: 'nameAm', label: 'Name (Amharic)' },
      { k: 'zone', label: 'Zone' },
      { k: 'latitude', label: 'Latitude', type: 'number', required: true },
      { k: 'longitude', label: 'Longitude', type: 'number', required: true },
      { k: 'hasShelter', label: 'Has shelter', type: 'bool' }
    ],
    map: function (row) {
      return {
        code: row.code, name: row.name, nameAm: row.nameAm, zone: row.zone,
        latitude: row.latitude, longitude: row.longitude, hasShelter: row.hasShelter
      };
    }
  },
  routes: {
    label: 'Routes',
    endpoint: '/admin/routes',
    needs: 'canManage',
    columns: function (r) {
      return [
        { t: r.code }, { t: r.name }, { t: r.mode, n: 1 },
        { t: r.operatorCode, n: 1 },
        { t: r.stops.length + ' stops', n: 1 },
        { t: r.distanceMeters ? (r.distanceMeters / 1000).toFixed(1) + ' km' : '—', n: 1 },
        { t: r.isActive ? statusTag('ACTIVE') : statusTag('SUSPENDED') }
      ];
    },
    fields: [
      { k: 'code', label: 'Code', required: true },
      { k: 'name', label: 'Name', required: true },
      { k: 'nameAm', label: 'Name (Amharic)' },
      { k: 'mode', label: 'Mode', type: 'enum', options: ['BUS', 'TAXI', 'TRAIN'], required: true },
      { k: 'operatorId', label: 'Operator', type: 'operator', required: true },
      { k: 'distanceMeters', label: 'Distance (m)', type: 'number' },
      { k: 'isActive', label: 'Active', type: 'bool' }
    ],
    map: function (row) {
      return {
        code: row.code, name: row.name, nameAm: row.nameAm, mode: row.mode,
        operatorId: row.operatorId, distanceMeters: row.distanceMeters,
        isActive: row.isActive
      };
    }
  },
  vehicles: {
    label: 'Vehicles',
    endpoint: '/admin/vehicles',
    needs: 'canManage',
    columns: function (v) {
      return [
        { t: v.plateNumber }, { t: v.operatorCode, n: 1 }, { t: v.mode, n: 1 },
        { t: ((v.make || '—') + ' ' + (v.model || '')).trim(), n: 1 },
        { t: v.capacity == null ? '—' : String(v.capacity), n: 1 },
        { t: statusTag(v.status) }
      ];
    },
    fields: [
      { k: 'plateNumber', label: 'Plate number', required: true },
      { k: 'operatorId', label: 'Operator', type: 'operator', required: true },
      { k: 'mode', label: 'Mode', type: 'enum', options: ['BUS', 'TAXI', 'TRAIN'], required: true },
      { k: 'make', label: 'Make' },
      { k: 'model', label: 'Model' },
      { k: 'capacity', label: 'Capacity', type: 'number' },
      { k: 'status', label: 'Status', type: 'enum',
        options: ['ACTIVE', 'MAINTENANCE', 'OUT_OF_SERVICE', 'RETIRED'] }
    ],
    map: function (row) {
      return {
        plateNumber: row.plateNumber, operatorId: row.operatorId, mode: row.mode,
        make: row.make, model: row.model, capacity: row.capacity, status: row.status
      };
    }
  },
  fareRules: {
    label: 'Fare rules',
    endpoint: '/admin/fare-rules',
    needs: 'canViewFares',
    // Deliberately no Edit column: a fare rule is revised, never edited.
    columns: function (r) {
      return [
        { t: r.ruleKey }, { t: 'v' + r.version, n: 1 }, { t: r.mode, n: 1 },
        { t: (r.originZone || 'any') + ' → ' + (r.destinationZone || 'any'), n: 1 },
        { t: money(r.baseFareFils) + (r.perKmFils ? ' + ' + money(r.perKmFils) + '/km' : ''), n: 1 },
        { t: shortDate(r.effectiveFrom), n: 1 },
        { t: statusTag(r.status) }
      ];
    },
    fields: [
      { k: 'ruleKey', label: 'Rule key', required: true },
      { k: 'mode', label: 'Mode', type: 'enum', options: ['BUS', 'TAXI', 'TRAIN'], required: true },
      { k: 'originZone', label: 'From zone' },
      { k: 'destinationZone', label: 'To zone' },
      { k: 'baseFareFils', label: 'Base fare (fils)', type: 'number', required: true },
      { k: 'perKmFils', label: 'Per km (fils)', type: 'number' },
      { k: 'minimumFareFils', label: 'Minimum fare (fils)', type: 'number' },
      { k: 'effectiveFrom', label: 'Effective from', type: 'date' },
      { k: 'changeReason', label: 'Reason for change', required: true, type: 'textarea' }
    ],
    map: function (row) {
      return {
        ruleKey: row.ruleKey, mode: row.mode, originZone: row.originZone,
        destinationZone: row.destinationZone, baseFareFils: row.baseFareFils,
        perKmFils: row.perKmFils, minimumFareFils: row.minimumFareFils,
        effectiveFrom: row.effectiveFrom, changeReason: row.changeReason
      };
    }
  },
  staff: {
    label: 'Staff',
    endpoint: '/admin/staff',
    needs: 'canManageStaff',
    columns: function (s) {
      return [
        { t: s.displayName || '—' }, { t: s.role, n: 1 },
        { t: s.employeeCode || '—', n: 1 },
        { t: s.operatorCode || 'city-wide', n: 1 },
        { t: s.isActive ? statusTag('ACTIVE') : statusTag('TERMINATED') }
      ];
    },
    fields: [
      { k: 'role', label: 'Role', type: 'enum', required: true,
        options: ['DRIVER', 'CONDUCTOR', 'INSPECTOR', 'TICKET_OFFICER', 'AGENT',
          'SUPERVISOR', 'OPERATOR_ADMIN', 'TRANSPORT_BUREAU_ADMIN', 'FINANCE',
          'AUDITOR', 'SUPER_ADMIN'] },
      { k: 'operatorId', label: 'Operator', type: 'operator' },
      { k: 'isActive', label: 'Active', type: 'bool' }
    ],
    map: function (row) {
      return { role: row.role, operatorId: row.operatorId, isActive: row.isActive };
    }
  }
};
/**
 * Renders the admin console: a resource picker, the current table, and a form
 * for the selected record. One panel rather than five, so switching resource
 * never means navigating away from the list the operator was reading.
 */
function renderManage(data) {
  var resourceKey = ADMIN_ACTIVE.resource;
  var spec = ADMIN_RESOURCES[resourceKey];

  // Resources the signed-in role may open. Filtered from the same permission
  // flags the server enforces, so the console does not offer a tab whose only
  // response would be a 403.
  var allowed = Object.keys(ADMIN_RESOURCES).filter(function (k) {
    var need = ADMIN_RESOURCES[k].needs;
    return !need || (data.permissions && data.permissions[need]);
  });

  if (allowed.indexOf(resourceKey) === -1) {
    resourceKey = allowed[0];
    ADMIN_ACTIVE.resource = resourceKey;
    spec = ADMIN_RESOURCES[resourceKey];
  }

  var html = '<div class="tabs">' + allowed.map(function (k) {
    return '<button class="tab' + (k === resourceKey ? ' active' : '') +
      '" data-admin-res="' + k + '">' + esc(ADMIN_RESOURCES[k].label) + '</button>';
  }).join('') + '</div>';

  var rows = (data.resources && data.resources[resourceKey]) || [];

  html += '<div class="box"><div class="box-head"><h3>' + esc(spec.label) +
    '</h3><div>' +
    (resourceKey === 'fareRules'
      // Fare rules get "New version", never "Edit".
      ? '<button class="btn" data-admin-new="' + resourceKey + '">New version</button>'
      : '<button class="btn primary" data-admin-new="' + resourceKey + '">New</button>') +
    '</div></div>';

  if (ADMIN_ACTIVE.editing) {
    html += adminForm(spec, ADMIN_ACTIVE.editing);
  } else if (rows.length === 0) {
    html += emptyState('No ' + spec.label.toLowerCase() + ' to show.');
  } else {
    html += '<div class="table-wrap"><table><thead><tr>' +
      rows.map(function (r, i) {
        return '<th class="' + (spec.columns(r)[i] && spec.columns(r)[i].n ? 'num' : '') +
          '">' + esc(adminHeader(spec, r, i)) + '</th>';
      }).join('') + '<th></th></tr></thead><tbody>' +
      rows.map(function (r, i) {
        var editable = resourceKey !== 'fareRules';
        return '<tr>' + spec.columns(r).map(function (c) {
          return '<td class="' + (c.n ? 'num' : '') + '">' + c.t + '</td>';
        }).join('') + '<td class="num">' +
          (editable ? '<button class="btn small" data-admin-edit="' + i + '">Edit</button> ' : '') +
          adminRowAction(resourceKey, r) +
          '</td></tr>';
      }).join('') + '</tbody></table></div>';
  }

  html += '</div>';
  html += '<div class="box"><p class="hint" style="margin:0">' +
    esc(ADMIN_NOTES[resourceKey]) + '</p></div>';

  render('manage', html);
  wireManage(spec);
}

/** Column headers, kept beside the column builders so the two cannot drift. */
function adminHeader(spec, row, index) {
  var column = spec.columns(row)[index];
  if (column && column.label) return column.label;
  return ADMIN_HEADERS[spec.label] && ADMIN_HEADERS[spec.label][index] || '';
}

function adminRowAction(resourceKey, row) {
  if (resourceKey === 'fareRules') {
    // Only a draft can be activated, and the server independently refuses a
    // self-approval, so the button is hidden rather than shown-and-rejected.
    return row.status === 'DRAFT'
      ? '<button class="btn small" data-admin-activate="' + row.id + '">Activate</button>'
      : '';
  }
  if (resourceKey === 'stops') {
    return '<button class="btn small" data-admin-toggle-stop="' + row.id +
      '" data-active="' + row.isActive + '">' + (row.isActive ? 'Deactivate' : 'Activate') + '</button>';
  }
  if (resourceKey === 'staff') {
    return '<button class="btn small" data-admin-toggle-staff="' + row.id +
      '" data-active="' + row.isActive + '">' + (row.isActive ? 'Terminate' : 'Reinstate') + '</button>';
  }
  return '';
}
/**
 * Per-resource column headers.
 *
 * Derived from the same order as the `columns` functions above; if a column list
 * is edited, update this too or the header shifts against its cell.
 */
var ADMIN_HEADERS = {
  Stops: ['Code', 'Name', 'Name (Am)', 'Zone', 'Position', 'Shelter', 'Status'],
  Routes: ['Code', 'Name', 'Mode', 'Operator', 'Stops', 'Distance', 'Status'],
  Vehicles: ['Plate', 'Operator', 'Mode', 'Make / model', 'Capacity', 'Status'],
  'Fare rules': ['Rule', 'Version', 'Mode', 'Zones', 'Fare', 'From', 'Status'],
  Staff: ['Name', 'Role', 'Employee', 'Operator', 'Status']
};

/** Explains the constraint that governs each resource, next to its controls. */
var ADMIN_NOTES = {
  stops: 'Stops are deactivated, never deleted: a stop that served a completed trip stays readable for audit.',
  routes: 'Routes are scoped to your operator unless you are bureau staff. Stops are assigned separately.',
  vehicles: 'Retiring a vehicle hides it from dispatch; its trips and shifts are unaffected.',
  fareRules: 'Fare rules are versioned. A change creates a new draft version and supersedes the previous one — issued tickets keep the exact rates they were priced with. A draft must be activated by someone other than its author.',
  staff: 'Changing a role is a privileged action and is written to the audit log. You cannot change your own role, and only a super admin can grant super admin.'
};

/** Transient UI state for the console: which resource, and the row being edited. */
var ADMIN_ACTIVE = { resource: 'stops', editing: null };

/** Operator choices for the dropdowns, fetched once per console load. */
var ADMIN_OPERATORS = [];

/** Builds the create/edit form for a resource. */
function adminForm(spec, editing) {
  var isNew = editing.__new;
  var title = (isNew ? 'New ' : 'Edit ') + spec.label.replace(/s$/, '').toLowerCase();

  return '<form class="admin-form" id="admin-form">' +
    '<div class="box-head"><h3>' + esc(title) + '</h3>' +
    '<button type="button" class="btn" data-admin-cancel>Cancel</button></div>' +
    '<div class="form-grid">' + spec.fields.map(function (f) {
      var value = editing[f.k];
      if (value === undefined || value === null) value = '';

      var input;
      if (f.type === 'bool') {
        input = '<select name="' + f.k + '">' +
          '<option value="true"' + (value === true ? ' selected' : '') + '>Yes</option>' +
          '<option value="false"' + (value === false ? ' selected' : '') + '>No</option>' +
          '</select>';
      } else if (f.type === 'enum') {
        input = '<select name="' + f.k + '"' + (f.required ? ' required' : '') + '>' +
          (value === '' ? '<option value="">—</option>' : '') +
          f.options.map(function (o) {
            return '<option value="' + esc(o) + '"' + (o === value ? ' selected' : '') +
              '>' + esc(o.replace(/_/g, ' ').toLowerCase()) + '</option>';
          }).join('') + '</select>';
      } else if (f.type === 'operator') {
        input = '<select name="' + f.k + '"' + (f.required ? ' required' : '') + '>' +
          '<option value="">—</option>' +
          ADMIN_OPERATORS.map(function (o) {
            return '<option value="' + esc(o.id) + '"' + (o.id === value ? ' selected' : '') +
              '>' + esc(o.code + ' — ' + o.name) + '</option>';
          }).join('') + '</select>';
      } else if (f.type === 'textarea') {
        input = '<textarea name="' + f.k + '"' + (f.required ? ' required' : '') +
          ' rows="2">' + esc(value) + '</textarea>';
      } else {
        input = '<input type="' + (f.type === 'number' ? 'number' : (f.type === 'date' ? 'date' : 'text')) +
          '" name="' + f.k + '" value="' + esc(value) + '"' +
          (f.required ? ' required' : '') + '>';
      }
      return '<label>' + esc(f.label) + (f.required ? ' <span class="req">*</span>' : '') +
        input + '</label>';
    }).join('') + '</div>' +
    '<div class="form-actions"><button type="submit" class="btn primary">Save</button>' +
    '<span class="hint" id="admin-error"></span></div></form>';
}

/** Binds the console's buttons and form. Delegated, so re-renders re-bind safely. */
function wireManage(spec) {
  var panel = document.getElementById('panel-manage');
  if (!panel) return;

  panel.querySelectorAll('[data-admin-res]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      ADMIN_ACTIVE.resource = btn.getAttribute('data-admin-res');
      ADMIN_ACTIVE.editing = null;
      loadPanel('manage', true);
    });
  });

  var newBtn = panel.querySelector('[data-admin-new]');
  if (newBtn) {
    newBtn.addEventListener('click', function () {
      ADMIN_ACTIVE.editing = { __new: true };
      loadPanel('manage', true);
    });
  }

  var cancel = panel.querySelector('[data-admin-cancel]');
  if (cancel) {
    cancel.addEventListener('click', function () {
      ADMIN_ACTIVE.editing = null;
      loadPanel('manage', true);
    });
  }

  panel.querySelectorAll('[data-admin-edit]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var rows = ADMIN_CACHE[ADMIN_ACTIVE.resource] || [];
      var row = rows[Number(btn.getAttribute('data-admin-edit'))];
      if (!row) return;
      // Only send fields the form actually shows, so a partial save cannot
      // blank a column the form does not know about.
      var mapped = spec.map(row);
      mapped.__new = false;
      // Carried with the form data so the save targets the row being edited
      // rather than whatever index the table happened to render.
      mapped.__id = row.id;
      ADMIN_ACTIVE.editing = mapped;
      loadPanel('manage', true);
    });
  });

  panel.querySelectorAll('[data-admin-toggle-stop]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      adminPost('/admin/stops/' + btn.getAttribute('data-admin-toggle-stop') + '/active',
        { isActive: btn.getAttribute('data-active') !== 'true' });
    });
  });

  panel.querySelectorAll('[data-admin-toggle-staff]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      adminPatch('/admin/staff/' + btn.getAttribute('data-admin-toggle-staff'),
        { isActive: btn.getAttribute('data-active') !== 'true' });
    });
  });

  panel.querySelectorAll('[data-admin-activate]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      adminPost('/admin/fare-rules/' + btn.getAttribute('data-admin-activate') + '/activate', {});
    });
  });

  var form = document.getElementById('admin-form');
  if (form) form.addEventListener('submit', function (event) { adminSave(event, spec); });
}

/** Last successful read per resource, used to populate edit forms. */
var ADMIN_CACHE = {};

/** Serialises a form into the payload shape the API expects. */
function adminPayload(form, spec) {
  var payload = {};
  spec.fields.forEach(function (f) {
    var raw = form.elements[f.k] ? form.elements[f.k].value : '';
    if (f.type === 'bool') {
      payload[f.k] = raw === 'true';
      return;
    }
    if (f.type === 'number') {
      // Empty means "not supplied" rather than zero, so an untouched numeric
      // field does not silently overwrite the stored value with 0.
      payload[f.k] = raw === '' ? undefined : Number(raw);
      return;
    }
    payload[f.k] = raw === '' ? null : raw;
  });
  return payload;
}

function adminSave(event, spec) {
  event.preventDefault();
  var form = event.target;
  var error = document.getElementById('admin-error');
  if (error) error.textContent = 'Saving…';

  var editing = ADMIN_ACTIVE.editing || {};
  var isNew = !!editing.__new;
  var resourceKey = ADMIN_ACTIVE.resource;

  var request;
  if (resourceKey === 'fareRules') {
    // Always a create: there is no update path for a fare rule, by design.
    request = api(spec.endpoint, { method: 'POST', body: JSON.stringify(adminPayload(form, spec)) });
  } else if (isNew) {
    request = api(spec.endpoint, { method: 'POST', body: JSON.stringify(adminPayload(form, spec)) });
  } else {
    request = api(spec.endpoint + '/' + editing.__id, {
      method: 'PATCH', body: JSON.stringify(adminPayload(form, spec))
    });
  }

  request.then(function () {
    ADMIN_ACTIVE.editing = null;
    return loadPanel('manage', true);
  }).catch(function (err) {
    if (error) error.textContent = (err && err.message) || 'Could not save';
  });
}

/** POST helper that surfaces server errors in the panel rather than the console. */
function adminPost(path, body) {
  return api(path, { method: 'POST', body: JSON.stringify(body) })
    .then(function () { return loadPanel('manage', true); })
    .catch(function (err) { alert((err && err.message) || 'Request failed'); });
}

/**
 * Loads every resource the console needs in one pass.
 *
 * Only the resources the signed-in role may actually see are requested. Fetching
 * a 403-prone endpoint to discover the role lacks access would fill the log with
 * rejections on every panel open and teach operators to ignore the errors.
 */
async function loadManage() {
  // Read from the session the server returned, so the console filters tabs by
  // the same permissions the API will enforce rather than by a client guess.
  var permissions = (state.session && state.session.permissions) || {};
  var specs = Object.keys(ADMIN_RESOURCES).filter(function (k) {
    var need = ADMIN_RESOURCES[k].needs;
    return !need || permissions[need];
  });

  var results = await Promise.all(specs.map(function (key) {
    return api(ADMIN_RESOURCES[key].endpoint + '?includeInactive=true')
      .then(function (rows) { return { key: key, rows: rows }; })
      .catch(function () { return { key: key, rows: [] }; });
  }));

  var resources = {};
  results.forEach(function (r) {
    ADMIN_CACHE[r.key] = r.rows;
    resources[r.key] = r.rows;
  });

  if (ADMIN_OPERATORS.length === 0) {
    // Operator choices back the route, vehicle and staff dropdowns. Failures are
    // swallowed: a console with empty dropdowns still lists and edits records
    // that do not need one.
    try {
      var ops = await api('/admin/operators');
      ADMIN_OPERATORS = ops;
    } catch (err) { ADMIN_OPERATORS = []; }
  }

  return { permissions: permissions, resources: resources };
}
function adminPatch(path, body) {
  return api(path, { method: 'PATCH', body: JSON.stringify(body) })
    .then(function () { return loadPanel('manage', true); })
    .catch(function (err) { alert((err && err.message) || 'Request failed'); });
}
/**
 * Addis One operations dashboard.
 *
 * Plain ES2017 in one file, no framework and no build step. The data volumes
 * are small (a month of payments, a handful of routes) and a reporting screen
 * is not where a dependency earns its keep; more importantly, this file has to
 * still work on an office machine in five years.
 */
'use strict';

// The API prefix is fixed rather than derived from the page URL, so the page
// keeps working if it is ever served from a subpath.
var API = '/api/v1';

// Kept in sessionStorage, not localStorage: a government dashboard on a shared
// office PC should not still be signed in after the browser closes. A stolen
// token from a closed tab is a much smaller problem than one that survives
// until someone signs out.
var TOKEN_KEY = 'addis.dashboard.token';

var state = {
  token: null,
  session: null,
  panel: 'overview',
  cache: {},
  page: 1,
  pageSize: 25,
  statusFilter: ''
};

/* ── Formatting ────────────────────────────────────────────────────────── */

// Money arrives as integer fils and is only ever divided at render time.
// The stored value never becomes a float, so no rounding error can accumulate;
// this mirrors formatMoney() in backend/src/common/money.ts.
function money(fils) {
  var n = Number(fils || 0);
  var sign = n < 0 ? '-' : '';
  n = Math.abs(n);
  var whole = Math.floor(n / 100);
  var cents = n % 100;
  return sign + whole.toLocaleString('en-ET') + '.' + (cents < 10 ? '0' + cents : cents) + ' ETB';
}

function num(n) {
  return Number(n || 0).toLocaleString('en-ET');
}

function pct(part, whole) {
  if (!whole) return '0%';
  return (part / whole * 100).toFixed(1) + '%';
}

function shortDate(iso) {
  if (!iso) return '—';
  return String(iso).slice(0, 10);
}

function dateTime(iso) {
  if (!iso) return '—';
  var d = new Date(iso);
  if (isNaN(d.getTime())) return '—';
  return d.toLocaleString('en-ET', {
    year: 'numeric', month: 'short', day: '2-digit',
    hour: '2-digit', minute: '2-digit'
  });
}

// Colours a status consistently across every table so an officer learns one
// mapping instead of re-reading labels: green is settled/good, yellow is
// in-flight, red is failed, grey is terminal-but-neutral.
function statusTag(status) {
  var s = String(status || '');
  var cls = 'grey';
  if (['CONFIRMED', 'COMPLETED', 'VALID', 'VALIDATED', 'TICKET_ISSUED', 'ACTIVE', 'SUPER_ADMIN',
       'TRANSPORT_BUREAU_ADMIN', 'FINANCE', 'AUDITOR'].indexOf(s) >= 0) cls = 'green';
  else if (['PENDING', 'CREATED', 'AUTHORIZED', 'REQUIRES_ACTION', 'IN_PROGRESS', 'BOARDING',
            'SCHEDULED', 'DELAYED', 'PENDING_APPROVAL'].indexOf(s) >= 0) cls = 'yellow';
  else if (['FAILED', 'TIMEOUT', 'REVERSED', 'REFUNDED', 'PARTIALLY_REFUNDED', 'SUSPENDED',
            'CANCELLED', 'VOIDED', 'EXPIRED', 'OUT_OF_SERVICE', 'RETIRED', 'TERMINATED'].indexOf(s) >= 0) cls = 'red';
  else if (['OPERATOR_ADMIN', 'SUPERVISOR', 'DRAFT', 'MAINTENANCE'].indexOf(s) >= 0) cls = 'blue';
  return '<span class="tag ' + cls + '">' + s.replace(/_/g, ' ') + '</span>';
}

function esc(s) {
  return String(s === null || s === undefined ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// Escapes a label for a `<title>`/tooltip context.
function deltaHtml(value, unit) {
  var n = Number(value || 0);
  var cls = n > 0 ? 'up' : (n < 0 ? 'down' : 'flat');
  var arrow = n > 0 ? '▲' : (n < 0 ? '▼' : '■');
  var text;
  if (unit === 'money') text = (n > 0 ? '+' : '') + money(n);
  else text = (n > 0 ? '+' : '') + num(n);
  return '<span class="delta ' + cls + '">' + arrow + ' ' + text + '</span>';
}

/* ── API client ────────────────────────────────────────────────────────── */

/**
 * Calls the API with the bearer token.
 *
 * A 401 means the session expired, so the token is dropped and the login
 * screen returns rather than leaving a half-rendered dashboard on screen. Any
 * other error is surfaced as text, because an officer staring at an empty panel
 * cannot tell "no data" from "the request failed" — and those need very
 * different responses from them.
 */
function api(path, options) {
  options = options || {};
  var headers = { 'Accept': 'application/json' };
  if (options.body) headers['Content-Type'] = 'application/json';
  if (state.token) headers['Authorization'] = 'Bearer ' + state.token;

  return fetch(API + path, {
    method: options.method || 'GET',
    headers: headers,
    body: options.body ? JSON.stringify(options.body) : undefined
  }).then(function (res) {
    if (res.status === 401) {
      signOut();
      throw new Error('Your session has expired. Please sign in again.');
    }
    return res.text().then(function (text) {
      var data = null;
      try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
      if (!res.ok) {
        var message = 'Request failed (' + res.status + ')';
        // Nest returns { message } and it is far more useful than the status.
        if (data && data.message) {
          message = Array.isArray(data.message) ? data.message.join(', ') : data.message;
        }
        var err = new Error(message);
        err.status = res.status;
        throw err;
      }
      return data;
    });
  });
}

/** The date window the filters currently describe. */
function range() {
  var from = document.getElementById('from').value;
  var to = document.getElementById('to').value;
  var q = [];
  if (from) q.push('from=' + encodeURIComponent(from));
  if (to) q.push('to=' + encodeURIComponent(to));
  return q.length ? '?' + q.join('&') : '';
}

/** Fills the date inputs to the last N days, matching the server's default. */
function applyPreset(days) {
  var to = new Date();
  var from = new Date();
  from.setDate(from.getDate() - (Number(days) - 1));
  document.getElementById('from').value = isoDate(from);
  document.getElementById('to').value = isoDate(to);
}

function isoDate(d) {
  return d.getFullYear() + '-' +
    String(d.getMonth() + 1).padStart(2, '0') + '-' +
    String(d.getDate()).padStart(2, '0');
}

/* ── Sign in ───────────────────────────────────────────────────────────── */

function showLoginError(message) {
  var el = document.getElementById('login-error');
  el.textContent = message;
  el.style.display = 'block';
}

function clearLoginError() {
  document.getElementById('login-error').style.display = 'none';
}

function sendOtp() {
  var phone = document.getElementById('phone').value.trim();
  if (!/^\+251[79]\d{8}$/.test(phone)) {
    // Checked here so the round trip is not spent on a number the API will
    // reject anyway; the server validates independently either way.
    showLoginError('Enter a valid Ethiopian mobile number, e.g. +251911000001');
    return;
  }
  clearLoginError();
  var btn = document.getElementById('btn-send');
  btn.disabled = true;
  btn.textContent = 'Sending…';

  api('/auth/request-otp', { method: 'POST', body: { phone: phone } })
    .then(function () {
      btn.disabled = false;
      btn.textContent = 'Send verification code';
      document.getElementById('step-phone').style.display = 'none';
      document.getElementById('step-code').style.display = 'block';
      document.getElementById('code').focus();
    })
    .catch(function (e) {
      btn.disabled = false;
      btn.textContent = 'Send verification code';
      showLoginError(e.message);
    });
}

function verifyOtp() {
  var phone = document.getElementById('phone').value.trim();
  var code = document.getElementById('code').value.trim();
  if (!/^\d{6}$/.test(code)) {
    showLoginError('Enter the six-digit code from your message.');
    return;
  }
  clearLoginError();
  var btn = document.getElementById('btn-verify');
  btn.disabled = true;
  btn.textContent = 'Signing in…';

  api('/auth/verify-otp', { method: 'POST', body: { phone: phone, code: code } })
    .then(function (data) {
      if (!data || !data.ok) {
        // The API answers 200 with ok:false for a wrong code, so a truthy
        // check here is what turns a silent no-op into a usable message.
        throw new Error('That code was not accepted. Check it and try again.');
      }
      state.token = data.accessToken;
      try { sessionStorage.setItem(TOKEN_KEY, state.token); } catch (e) { /* private mode */ }
      btn.disabled = false;
      btn.textContent = 'Sign in';
      return start();
    })
    .catch(function (e) {
      btn.disabled = false;
      btn.textContent = 'Sign in';
      showLoginError(e.message);
    });
}

/**
 * Development shortcut: sign in without an OTP round trip.
 *
 * Revealed by asking the server whether the route is armed, rather than by a build
 * flag in the page. The page is a static file with no access to server
 * configuration, so a client-side switch would either be always-on (offering a
 * button that 404s in production) or hand-edited (and wrong the moment the server
 * config changed). Asking keeps the control and the capability in agreement
 * automatically.
 *
 * GET /auth/dev-login answers the capability question and has no side effects.
 * Probing the POST route instead would not distinguish "route not registered" from
 * "route live but this number is not staff" — both are 404 — so the button would
 * never appear even when the feature was working.
 */
function probeDevLogin() {
  return api('/auth/dev-login', { method: 'GET' })
    .then(function (data) {
      return !!(data && data.enabled);
    })
    .catch(function () {
      // 404 means the guard is refusing, i.e. the feature is off. Any other
      // failure also leaves the control hidden: an unreachable server should not
      // present a sign-in button.
      return false;
    });
}

function devLogin() {
  var phone = document.getElementById('phone').value.trim();
  if (!/^\+251[79]\d{8}$/.test(phone)) {
    showLoginError('Enter a valid Ethiopian mobile number, e.g. +251911000001');
    return;
  }
  clearLoginError();
  var btn = document.getElementById('btn-dev-login');
  btn.disabled = true;
  btn.textContent = 'Signing in…';

  api('/auth/dev-login', { method: 'POST', body: { phone: phone } })
    .then(function (data) {
      if (!data || !data.ok || !data.accessToken) {
        throw new Error('Development sign-in was refused. Use the verification code instead.');
      }
      state.token = data.accessToken;
      try { sessionStorage.setItem(TOKEN_KEY, state.token); } catch (e) { /* private mode */ }
      btn.disabled = false;
      btn.textContent = 'Sign in without a code';
      return start();
    })
    .catch(function (e) {
      btn.disabled = false;
      btn.textContent = 'Sign in without a code';
      showLoginError(e.message);
    });
}

function signOut() {
  // Revoke server-side first so the refresh token dies with the session, but do
  // not block the UI on it: a network failure must not strand the user in a
  // signed-in shell they are trying to leave.
  if (state.token) {
    api('/auth/logout', { method: 'POST' }).catch(function () {});
  }

  state.token = null;
  state.session = null;
  state.cache = {};
  try { sessionStorage.removeItem(TOKEN_KEY); } catch (e) { /* ignore */ }
  document.getElementById('app').classList.remove('ready');
  document.getElementById('login').style.display = 'flex';
  document.getElementById('step-phone').style.display = 'block';
  document.getElementById('step-code').style.display = 'none';
  document.getElementById('code').value = '';
}

/* ── Charts ────────────────────────────────────────────────────────────── */

/**
 * Draws a line chart as inline SVG.
 *
 * Hand-rolled rather than pulled from a library for the same reason the page
 * has no CDN: nothing here can fail to load. The viewBox scales to the panel,
 * so the same markup is correct on a laptop and on a projector.
 *
 * The axis deliberately starts at zero. A revenue chart with a truncated axis
 * turns a quiet week into a dramatic cliff, which is exactly the misreading a
 * bureau dashboard exists to prevent.
 */
function lineChart(points, opts) {
  opts = opts || {};
  var w = 720, h = 200, padL = 58, padR = 12, padT = 12, padB = 26;
  if (!points || points.length === 0) {
    return '<div class="state">No activity in this period.</div>';
  }

  var values = points.map(function (p) { return Number(p.value) || 0; });
  var max = Math.max.apply(null, values);
  if (max === 0) max = 1; // avoid a divide-by-zero flat line
  var innerW = w - padL - padR;
  var innerH = h - padT - padB;
  var stepX = points.length > 1 ? innerW / (points.length - 1) : 0;

  function x(i) { return padL + (points.length > 1 ? i * stepX : innerW / 2); }
  function y(v) { return padT + innerH - (Number(v) || 0) / max * innerH; }

  var line = points.map(function (p, i) {
    return (i === 0 ? 'M' : 'L') + x(i).toFixed(1) + ' ' + y(p.value).toFixed(1);
  }).join(' ');

  // Area under the line gives the shape visual weight at a glance.
  var area = line + ' L' + x(points.length - 1).toFixed(1) + ' ' + (padT + innerH) +
    ' L' + x(0).toFixed(1) + ' ' + (padT + innerH) + ' Z';

  var grid = '';
  [0, 0.25, 0.5, 0.75, 1].forEach(function (t) {
    var gy = padT + innerH - t * innerH;
    grid += '<line x1="' + padL + '" y1="' + gy.toFixed(1) + '" x2="' + (w - padR) +
      '" y2="' + gy.toFixed(1) + '" stroke="#E3E9E6" stroke-width="1"/>';
    grid += '<text x="' + (padL - 8) + '" y="' + (gy + 4).toFixed(1) +
      '" text-anchor="end" font-size="11" fill="#5B6B65">' +
      (opts.money ? money(max * t).replace(' ETB', '') : num(Math.round(max * t))) + '</text>';
  });

  // Label roughly six dates regardless of range length, so a 90-day view does
  // not render 90 overlapping labels.
  var labels = '';
  var every = Math.max(1, Math.floor(points.length / 6));
  points.forEach(function (p, i) {
    if (i % every !== 0 && i !== points.length - 1) return;
    labels += '<text x="' + x(i).toFixed(1) + '" y="' + (h - 6) +
      '" text-anchor="middle" font-size="11" fill="#5B6B65">' + esc(shortDate(p.day)) + '</text>';
  });

  var dots = '';
  if (points.length <= 40) {
    points.forEach(function (p, i) {
      dots += '<circle cx="' + x(i).toFixed(1) + '" cy="' + y(p.value).toFixed(1) +
        '" r="2.5" fill="#0F8B4D"/>';
    });
  }

  var color = opts.color || '#0F8B4D';
  return '<svg viewBox="0 0 ' + w + ' ' + h + '" width="100%" height="' + h +
    '" role="img" aria-label="' + esc(opts.label || 'Trend') + '">' +
    grid +
    '<path d="' + area + '" fill="' + color + '" opacity="0.10"/>' +
    '<path d="' + line + '" fill="none" stroke="' + color + '" stroke-width="2" ' +
    'stroke-linejoin="round" stroke-linecap="round"/>' +
    dots + labels + '</svg>';
}

/** Horizontal bars, used where the categories are names rather than dates. */
function barList(rows, opts) {
  opts = opts || {};
  if (!rows || rows.length === 0) {
    return '<div class="state">Nothing to show yet.</div>';
  }
  var max = Math.max.apply(null, rows.map(function (r) { return Number(r.value) || 0; })) || 1;
  return '<div class="bars">' + rows.map(function (r) {
    var width = Math.max(2, (Number(r.value) || 0) / max * 100);
    return '<div class="bar-row">' +
      '<div title="' + esc(r.label) + '">' + esc(r.label) + '</div>' +
      '<div class="bar-track"><div class="bar-fill' + (opts.blue ? ' blue' : '') +
      '" style="width:' + width.toFixed(1) + '%"></div></div>' +
      '<div class="bar-val">' + (opts.money ? money(r.value) : num(r.value)) + '</div>' +
      '</div>';
  }).join('') + '</div>';
}

function errorState(message) {
  return '<div class="state error">' + esc(message) + '</div>';
}

function emptyState(message) {
  return '<div class="state">' + esc(message) + '</div>';
}

/** Renders a panel, replacing its "Loading…" placeholder. */
function render(panelId, html) {
  document.getElementById('panel-' + panelId).innerHTML = html;
}

/* ── Panels ────────────────────────────────────────────────────────────── */

function renderOverview(data) {
  var k = data.kpis;
  var pop = data.periodOverPeriod;
  var n = data.network;
  var a = data.passengers.accounts;

  var cards = [
    { label: 'Settled revenue', value: money(k.settledRevenueFils),
      sub: num(k.settledPaymentCount) + ' confirmed payments',
      delta: pop.settledRevenueFils, unit: 'money' },
    { label: 'Tickets issued', value: num(k.ticketsIssued),
      sub: num(k.ticketCount) + ' ticket records', delta: pop.ticketCount },
    { label: 'Journeys planned', value: num(k.journeyCount),
      sub: num(data.passengers.journeysInRange) + ' with a fare', delta: pop.journeyCount },
    { label: 'Average ticket', value: money(k.averageTicketFils),
      sub: 'per confirmed payment', delta: null },
    { label: 'Unsettled payments', value: num(k.unsettledPaymentCount),
      sub: k.refundFils ? money(k.refundFils) + ' refunded' : 'none pending', delta: null },
    { label: 'Active network', value: num(n.activeRoutes) + ' routes',
      sub: num(n.servedStops) + ' of ' + num(n.activeStops) + ' stops served', delta: null }
  ];

  var html = '<div class="cards">' + cards.map(function (c) {
    return '<div class="card"><div class="label">' + esc(c.label) + '</div>' +
      '<div class="value">' + esc(c.value) + '</div>' +
      '<div class="sub">' + esc(c.sub) + '</div>' +
      (c.delta === null || c.delta === undefined ? '' : deltaHtml(c.delta, c.unit)) +
      '</div>';
  }).join('') + '</div>';

  html += '<div class="box"><h3>Settled revenue by day</h3>' +
    lineChart(data.series.revenue.map(function (p) {
      return { day: p.day, value: p.revenueFils };
    }), { money: true, label: 'Daily settled revenue' }) +
    '<div class="legend"><span><i style="background:#0F8B4D"></i>Confirmed payments only</span>' +
    '<span>Compared with the ' + esc(pop.days) + ' days before this window</span></div></div>';

  html += '<div class="grid2">';

  html += '<div class="box"><h3>Journeys planned by day</h3>' +
    lineChart(data.series.journeys.map(function (p) {
      return { day: p.day, value: p.journeys };
    }), { color: '#1D6FE0', label: 'Daily journeys' }) + '</div>';

  html += '<div class="box"><h3>Stops by zone</h3>' +
    barList(n.stopsByZone.map(function (z) { return { label: z.zone, value: z.count }; })) +
    '<div class="legend"><span>' + num(n.activeStops - n.unservedStops) +
    ' of ' + num(n.activeStops) + ' active stops are served by a route</span></div></div>';
  html += '</div>';

  render('overview', html + accountTables(data));
}

/** Account lifecycle and concession tables, shared by Overview and Passengers. */
function accountTables(data) {
  var a = data.passengers.accounts;
  var html = '<div class="grid2">';
  html += '<div class="box"><h3>Citizen accounts</h3><div class="table-wrap"><table>' +
    '<thead><tr><th>Measure</th><th class="num">Count</th></tr></thead><tbody>' +
    '<tr><td>Total registered</td><td class="num">' + num(a.total) + '</td></tr>' +
    '<tr><td>Active</td><td class="num">' + num(a.active) + '</td></tr>' +
    '<tr><td>Phone verified</td><td class="num">' + num(a.phoneVerified) + '</td></tr>' +
    '<tr><td>Pending verification</td><td class="num">' + num(a.pending) + '</td></tr>' +
    '<tr><td>Suspended</td><td class="num">' + num(a.suspended) + '</td></tr>' +
    '<tr><td>New in this period</td><td class="num">' + num(a.newInRange) + '</td></tr>' +
    '</tbody></table></div></div>';

  var c = data.passengers.concessions;
  html += '<div class="box"><h3>Concession entitlements</h3>' +
    (c.length === 0
      ? emptyState('No concessions are configured.')
      : '<div class="table-wrap"><table><thead><tr><th>Concession</th>' +
        '<th class="num">Discount</th><th class="num">Holders</th></tr></thead><tbody>' +
        c.map(function (x) {
          return '<tr><td>' + esc(x.name) + '</td><td class="num">' +
            num(x.discountPercent) + '%</td><td class="num">' + num(x.holders) + '</td></tr>';
        }).join('') + '</tbody></table></div>') + '</div>';
  return html + '</div>';
}

function renderRevenue(data) {
  var t = data.totals;
  var html = '<div class="cards">' +
    '<div class="card"><div class="label">Gross collected</div><div class="value">' +
      money(t.grossFils) + '</div><div class="sub">' + num(t.grossCount) + ' payments</div></div>' +
    '<div class="card"><div class="label">Settled</div><div class="value">' +
      money(t.confirmedFils) + '</div><div class="sub">' + num(t.confirmedCount) + ' confirmed</div></div>' +
    '<div class="card"><div class="label">In flight</div><div class="value">' +
      num(t.pendingCount) + '</div><div class="sub">' + money(t.pendingFils) + ' not settled</div></div>' +
    '<div class="card"><div class="label">Refunded / reversed</div><div class="value">' +
      money(t.refundedFils) + '</div><div class="sub">' + num(t.refundedCount) + ' payments</div></div>' +
    '</div>';

  html += '<div class="grid2">' +
    '<div class="box"><h3>By status</h3>' +
      barList(data.byStatus.map(function (r) {
        return { label: r.status.replace(/_/g, ' '), value: r.amountFils };
      }), { money: true }) + '</div>' +
    '<div class="box"><h3>By payment method</h3>' +
      barList(data.byMethod.map(function (r) {
        return { label: r.method.replace(/_/g, ' '), value: r.amountFils };
      }), { money: true, blue: true }) + '</div></div>';

  // Counts matter as much as amounts: a healthy total alongside a pile of
  // FAILED rows is a very different picture from a healthy total alone.
  html += '<div class="box"><h3>Transaction counts by status</h3><div class="table-wrap"><table>' +
    '<thead><tr><th>Status</th><th class="num">Count</th><th class="num">Amount</th>' +
    '<th class="num">Share</th></tr></thead><tbody>' +
    (data.byStatus.length === 0
      ? '<tr><td colspan="4">' + emptyState('No payments in this period.') + '</td></tr>'
      : data.byStatus.map(function (r) {
          return '<tr><td>' + statusTag(r.status) + '</td><td class="num">' + num(r.count) +
            '</td><td class="num">' + money(r.amountFils) + '</td><td class="num">' +
            pct(r.count, data.total) + '</td></tr>';
        }).join('')) +
    '</tbody></table></div></div>';

  html += '<div class="box"><h3>Recent payments</h3>';
  if (data.payments.length === 0) {
    html += emptyState('No payments match this filter.');
  } else {
    html += '<div class="table-wrap"><table><thead><tr><th>Reference</th><th>Method</th>' +
      '<th>Status</th><th class="num">Amount</th><th>Raised</th><th>Confirmed</th></tr></thead><tbody>' +
      data.payments.map(function (p) {
        return '<tr><td>' + esc(p.reference) + '</td><td>' + esc(p.method.replace(/_/g, ' ')) +
          '</td><td>' + statusTag(p.status) + '</td><td class="num">' + money(p.amountFils) +
          '</td><td>' + esc(dateTime(p.createdAt)) + '</td><td>' + esc(dateTime(p.confirmedAt)) +
          '</td></tr>';
      }).join('') + '</tbody></table></div>' +
      '<div class="pager">' +
      '<button class="btn small ghost" id="prev-page"' + (data.page <= 1 ? ' disabled' : '') +
      '>Previous</button><span>Page ' + data.page + ' of ' + data.pageCount +
      ' &middot; ' + num(data.total) + ' payments</span>' +
      '<button class="btn small ghost" id="next-page"' +
      (data.page >= data.pageCount ? ' disabled' : '') + '>Next</button></div>';
  }
  render('revenue', html + '</div>');

  var prev = document.getElementById('prev-page');
  var next = document.getElementById('next-page');
  if (prev) prev.addEventListener('click', function () {
    if (state.page > 1) { state.page--; loadPanel('revenue', true); }
  });
  if (next) next.addEventListener('click', function () {
    state.page++;
    loadPanel('revenue', true);
  });
}

function renderOperations(data) {
  var t = data.tickets;
  var j = data.journeys;
  var html = '<div class="cards">' +
    '<div class="card"><div class="label">Tickets issued</div><div class="value">' +
      num(t.issued) + '</div><div class="sub">valid fare documents</div></div>' +
    '<div class="card"><div class="label">Ticket records</div><div class="value">' +
      num(t.total) + '</div><div class="sub">all states</div></div>' +
    '<div class="card"><div class="label">Journeys planned</div><div class="value">' +
      num(j.total) + '</div><div class="sub">' + num(j.zeroFare) + ' zero-fare</div></div>' +
    '<div class="card"><div class="label">Paid journeys</div><div class="value">' +
      num(j.withFare) + '</div><div class="sub">of ' + num(j.total) + ' planned</div></div>' +
    '</div>';

  html += '<div class="grid2">' +
    '<div class="box"><h3>Tickets by status</h3>' +
      barList(t.byStatus.map(function (r) {
        return { label: r.status.replace(/_/g, ' '), value: r.count };
      })) + '</div>' +
    '<div class="box"><h3>Tickets by mode</h3>' +
      barList(t.byMode.map(function (r) {
        return { label: r.mode.replace(/_/g, ' '), value: r.count };
      }), { blue: true }) + '</div></div>';

  html += '<div class="box"><h3>Ticket states</h3><div class="table-wrap"><table>' +
    '<thead><tr><th>Status</th><th class="num">Count</th><th class="num">Share of issued</th>' +
    '</tr></thead><tbody>' +
    (t.byStatus.length === 0
      ? '<tr><td colspan="3">' + emptyState('No tickets in this period.') + '</td></tr>'
      : t.byStatus.map(function (r) {
          return '<tr><td>' + statusTag(r.status) + '</td><td class="num">' + num(r.count) +
            '</td><td class="num">' + pct(r.count, t.issued) + '</td></tr>';
        }).join('')) +
    '</tbody></table></div></div>';

  render('operations', html);
}

function renderNetwork(data) {
  var html = '<div class="cards">' +
    '<div class="card"><div class="label">Routes</div><div class="value">' +
      num(data.routes) + '</div><div class="sub">' + num(data.activeRoutes) + ' active</div></div>' +
    '<div class="card"><div class="label">Stops</div><div class="value">' +
      num(data.stops) + '</div><div class="sub">' + num(data.activeStops) + ' active</div></div>' +
    '<div class="card"><div class="label">Served stops</div><div class="value">' +
      num(data.servedStops) + '</div><div class="sub">called at by an active route</div></div>' +
    '<div class="card"><div class="label">Coverage gaps</div><div class="value">' +
      num(data.unservedStops) + '</div><div class="sub">active but not served</div></div>' +
    '<div class="card"><div class="label">Operators</div><div class="value">' +
      num(data.operators) + '</div><div class="sub">in this view</div></div>' +
    '</div>';

  html += '<div class="box"><h3>Stops by zone</h3>' +
    barList(data.stopsByZone.map(function (z) { return { label: z.zone, value: z.count }; })) +
    '<div class="legend"><span>Zones are the fare basis: a journey is priced by the ' +
    'zone it starts and ends in.</span></div></div>';

  render('network', html);
}

function renderFares(data) {
  var t = data.totals;
  var html = '<div class="cards">' +
    '<div class="card"><div class="label">Rule keys</div><div class="value">' +
      num(t.keys) + '</div><div class="sub">distinct pricing policies</div></div>' +
    '<div class="card"><div class="label">Active versions</div><div class="value">' +
      num(t.active) + '</div><div class="sub">currently applied</div></div>' +
    '<div class="card"><div class="label">Superseded</div><div class="value">' +
      num(t.superseded) + '</div><div class="sub">kept for disputes</div></div>' +
    '<div class="card"><div class="label">Awaiting approval</div><div class="value">' +
      num(t.pendingApproval) + '</div><div class="sub">' + num(t.draft) + ' in draft</div></div>' +
    '</div>';

  html += '<div class="box"><h3>Fare rule versions</h3>' +
    '<p class="hint" style="margin-top:0">Superseded versions are retained so a ticket ' +
    'issued under an older policy can still be explained. Deleting them would make ' +
    'historical charges unexplainable.</p>' +
    '<div class="table-wrap"><table><thead><tr><th>Rule</th><th class="num">Version</th>' +
    '<th>Status</th><th>Applies to</th><th class="num">Base</th><th class="num">Per km</th>' +
    '<th class="num">Minimum</th><th>Effective</th><th>Reason</th></tr></thead><tbody>';

  var rows = [];
  data.groups.forEach(function (g) {
    g.versions.forEach(function (v) {
      rows.push('<tr><td>' + esc(g.ruleKey) + '</td><td class="num">' + num(v.version) + '</td>' +
        '<td>' + statusTag(v.status) + '</td><td>' + esc(fareApplies(v)) + '</td>' +
        '<td class="num">' + money(v.baseFareFils) + '</td>' +
        '<td class="num">' + money(v.perKmFils) + '</td>' +
        '<td class="num">' + money(v.minimumFareFils) + '</td>' +
        '<td>' + esc(shortDate(v.effectiveFrom)) + ' &rarr; ' +
        (v.effectiveUntil ? esc(shortDate(v.effectiveUntil)) : 'current') + '</td>' +
        '<td>' + esc(v.changeReason || '—') + '</td></tr>');
    });
  });

  html += (rows.length === 0
    ? '<tr><td colspan="9">' + emptyState('No fare rules are configured.') + '</td></tr>'
    : rows.join(''));
  render('fares', html + '</tbody></table></div></div>');
}

/** Describes what a fare rule matches, in the words an officer would use. */
function fareApplies(v) {
  if (v.originZone && v.destinationZone) return v.originZone + ' → ' + v.destinationZone;
  if (v.originZone) return v.originZone + ' → all';
  return 'All journeys';
}

function renderPassengers(data) {
  var html = accountTables({ passengers: data });
  html += '<div class="box"><h3>Activity in this period</h3>' +
    '<div class="table-wrap"><table><tbody>' +
    '<tr><td>Journeys planned with a fare</td><td class="num">' +
      num(data.journeysInRange) + '</td></tr>' +
    '<tr><td>New citizen accounts in this period</td><td class="num">' +
      num(data.accounts.newInRange) + '</td></tr>' +
    '</tbody></table></div>' +
    '<div class="legend"><span>Counts only. This dashboard never lists individual ' +
    'citizens — names, phone numbers and national IDs are deliberately not exposed here.</span>' +
    '</div></div>';
  render('passengers', html);
}

/* ── Loading and boot ──────────────────────────────────────────────────── */

var RENDERERS = {
  overview: { path: '/dashboard/overview', render: renderOverview },
  revenue: { path: '/dashboard/revenue', render: renderRevenue, needs: 'canViewFinance' },
  operations: { path: '/dashboard/operations', render: renderOperations },
  network: { path: '/dashboard/network', render: renderNetwork },
  fares: { path: '/dashboard/fares', render: renderFares, needs: 'canViewFares' },
  passengers: { path: '/dashboard/passengers', render: renderPassengers },
  database: { path: '/dashboard/database', render: renderDatabase, needs: 'canViewDatabase' },
  manage: { load: loadManage, render: renderManage, needs: 'canManage' }
};

function loadPanel(name, force) {
  var spec = RENDERERS[name];
  if (!spec) return Promise.resolve();

  // Panels are fetched on first view and then kept, so switching tabs is
  // instant. Refresh clears the cache explicitly rather than every tab
  // re-fetching behind the officer's back.
  if (!force && state.cache[name]) return Promise.resolve(state.cache[name]);

  if (name !== 'overview' && name !== 'network') {
    render(name, '<div class="state">Loading…</div>');
  }

  // A panel with its own loader fetches several endpoints and shapes them into
  // one view (the admin console); everything else is a single GET.
  if (typeof spec.load === 'function') {
    return spec.load()
      .then(function (data) {
        state.cache[name] = data;
        spec.render(data);
      })
      .catch(function (e) {
        render(name, errorState(e.message));
      });
  }

  var path = spec.path + (name === 'overview' || name === 'operations' || name === 'passengers'
    ? range()
    : '');
  if (name === 'revenue') {
    path += (path.indexOf('?') >= 0 ? '&' : '?') +
      'page=' + state.page + '&pageSize=' + state.pageSize;
  }

  return api(path)
    .then(function (data) {
      state.cache[name] = data;
      spec.render(data);
    })
    .catch(function (e) {
      // A 403 on a panel the role should not see is not an error to shout
      // about; the tab is hidden before it can be clicked, so this is almost
      // always a genuine failure worth showing.
      render(name, errorState(e.message));
    });
}

function showPanel(name) {
  state.panel = name;
  Array.prototype.forEach.call(document.querySelectorAll('nav.tabs button'), function (b) {
    b.classList.toggle('active', b.getAttribute('data-panel') === name);
  });
  Array.prototype.forEach.call(document.querySelectorAll('.panel'), function (p) {
    p.classList.toggle('active', p.id === 'panel-' + name);
  });
  loadPanel(name);
}

function refreshAll() {
  state.cache = {};
  state.page = 1;
  return loadPanel(state.panel, true);
}

/** Hides tabs the signed-in role may not open. */
function applyPermissions(permissions) {
  Object.keys(RENDERERS).forEach(function (name) {
    var need = RENDERERS[name].needs;
    if (need && !permissions[need]) {
      var btn = document.querySelector('nav.tabs button[data-panel="' + name + '"]');
      if (btn) btn.parentNode.removeChild(btn);
    }
  });

  // Never leave the operator on a tab that was just removed.
  if (!document.querySelector('nav.tabs button[data-panel="' + state.panel + '"]')) {
    showPanel('overview');
  }
}

function start() {
  return api('/dashboard/session')
    .then(function (session) {
      state.session = session;
      document.getElementById('login').style.display = 'none';
      document.getElementById('app').classList.add('ready');

      var s = session.staff;
      document.getElementById('who').textContent =
        s.display + '  ·  ' + s.role.replace(/_/g, ' ') +
        (session.permissions.cityWide ? '  ·  city-wide' : '  ·  operator scope');
      document.getElementById('foot').textContent =
        'Addis One Operations Dashboard · signed in as ' + s.display;

      applyPermissions(session.permissions);
      return showPanel('overview');
    })
    .catch(function (e) {
      // A valid citizen token reaches this point and is refused here. Saying so
      // plainly is more useful than bouncing them to an empty login form.
      signOut();
      showLoginError(e.message || 'This account cannot access the dashboard.');
    });
}

/* ── Wiring ────────────────────────────────────────────────────────────── */

document.getElementById('btn-send').addEventListener('click', sendOtp);
document.getElementById('btn-verify').addEventListener('click', verifyOtp);
document.getElementById('btn-dev-login').addEventListener('click', devLogin);

// Ask the server whether the development shortcut is armed and reveal the
// control only if it is. Silent on failure: the normal OTP path is unaffected
// either way, which is the point of keeping this off the critical path.
probeDevLogin().then(function (on) {
  if (on) document.getElementById('dev-login-row').style.display = 'block';
});

document.getElementById('btn-signout').addEventListener('click', signOut);
document.getElementById('btn-refresh').addEventListener('click', function () {
  refreshAll();
});
document.getElementById('back-to-phone').addEventListener('click', function (e) {
  e.preventDefault();
  document.getElementById('step-phone').style.display = 'block';
  document.getElementById('step-code').style.display = 'none';
  document.getElementById('code').value = '';
});

// Enter submits, because an officer typing a code should not have to reach the
// mouse to finish signing in.
document.getElementById('phone').addEventListener('keydown', function (e) {
  if (e.key === 'Enter') sendOtp();
});
document.getElementById('code').addEventListener('keydown', function (e) {
  if (e.key === 'Enter') verifyOtp();
});

document.getElementById('preset').addEventListener('change', function (e) {
  applyPreset(e.target.value);
  state.page = 1;
  refreshAll();
});

// A hand-edited date must take effect; otherwise the officer changes the dates
// and the screen silently keeps showing the preset range.
['from', 'to'].forEach(function (id) {
  document.getElementById(id).addEventListener('change', function () {
    state.page = 1;
    refreshAll();
  });
});

Array.prototype.forEach.call(document.querySelectorAll('nav.tabs button'), function (b) {
  b.addEventListener('click', function () {
    showPanel(b.getAttribute('data-panel'));
  });
});

// Boot: restore a token if one survived a reload, otherwise show sign-in.
applyPreset(30);
try {
  var saved = sessionStorage.getItem(TOKEN_KEY);
  if (saved) {
    state.token = saved;
    start();
  }
} catch (e) {
  // Storage unavailable (private browsing); the login form still works.
}
