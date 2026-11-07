(() => {
  const page = document.body.dataset.page;
  const vi = new Intl.NumberFormat('vi-VN', { maximumFractionDigits: 0 });
  const vi2 = new Intl.NumberFormat('vi-VN', { maximumFractionDigits: 2 });
  const charts = new Map();
  const colors = { blue: '#4c7be0', teal: '#25b2a4', violet: '#927ad9', amber: '#e9a955', gray: '#b6c4d8' };
  let catalog = null;
  let runId = null;
  const runCache = new Map();
  const comparisonCache = new Map();
  const getRun = id => {
    if (!runCache.has(id)) runCache.set(id, api(`/api/dss/run/${id}`).catch(error => { runCache.delete(id); throw error; }));
    return runCache.get(id);
  };
  const getComparison = (id, months) => {
    const key = `${id}:${months}`;
    if (!comparisonCache.has(key)) comparisonCache.set(key, api(`/api/dss/compare?candidateRunId=${id}&months=${months}`).catch(error => { comparisonCache.delete(key); throw error; }));
    return comparisonCache.get(key);
  };

  const el = id => document.getElementById(id);
  const metric = (name, value) => {
    const node = document.querySelector(`[data-metric="${name}"]`);
    if (node) node.textContent = value == null ? '' : String(value);
  };
  const fmt = value => vi.format(Number(value) || 0);
  const money = value => vi2.format((Number(value) || 0) / 1000000);
  const percent = value => `${vi2.format((Number(value) || 0) * 100)}%`;
  const isoDate = key => `${String(key).slice(0, 4)}-${String(key).slice(4, 6)}-${String(key).slice(6, 8)}`;
  const shortDate = value => value ? new Date(value).toLocaleDateString('vi-VN') : 'Đang thực hiện';
  const monthLabel = key => `${String(key).slice(4, 6)}/${String(key).slice(0, 4)}`;

  async function api(path) {
    const response = await fetch(path, { cache: 'no-store' });
    if (!response.ok) throw new Error(`Chưa thể cập nhật dữ liệu (${response.status}). Vui lòng thử lại.`);
    return response.json();
  }

  function showError(message) {
    const box = document.createElement('div');
    box.className = 'alert alert-warning mx-auto my-3';
    box.textContent = message;
    document.querySelector('.page-content')?.prepend(box);
  }

  function chart(id, config) {
    const canvas = el(id);
    if (!canvas || typeof Chart === 'undefined') return;
    charts.get(id)?.destroy();
    canvas.hidden = false;
    const prior = canvas.previousElementSibling;
    if (prior?.classList.contains('donut-placeholder')) prior.hidden = true;
    charts.set(id, new Chart(canvas, config));
  }

  function donut(id, segments) {
    const valid = (segments || []).filter(item => Number(item.value) > 0);
    if (!valid.length) return;
    const palette = [colors.teal, colors.blue, colors.amber, colors.violet, colors.gray];
    chart(id, {
      type: 'doughnut',
      data: { labels: valid.map(x => x.label), datasets: [{ data: valid.map(x => x.value),
        backgroundColor: valid.map((_, i) => palette[i % palette.length]),
        borderColor: '#fff', borderWidth: 4, borderRadius: 5, hoverOffset: 9 }] },
      options: { responsive: true, maintainAspectRatio: false, cutout: '72%', animation: { duration: 850 },
        plugins: { legend: { display: false }, tooltip: { callbacks: { label: item => `${item.label}: ${fmt(item.parsed)}` } } } }
    });
  }

  function seriesChart(id, labels, baseValues, candidateValues, kind = 'line', unit = '') {
    const canvas = el(id);
    if (!canvas) return;
    const blueGradient = canvas.getContext('2d').createLinearGradient(0, 0, 0, 260);
    blueGradient.addColorStop(0, 'rgba(76,123,224,.25)');
    blueGradient.addColorStop(1, 'rgba(76,123,224,0)');
    chart(id, {
      type: kind,
      data: { labels, datasets: [
        { label: 'ROP', data: baseValues, borderColor: colors.gray, backgroundColor: kind === 'bar' ? colors.gray : 'rgba(182,196,216,.06)',
          borderWidth: 2, tension: .35, fill: false, pointRadius: 2, borderRadius: 5, maxBarThickness: 16 },
        { label: 'Quetschlich Adapt', data: candidateValues, borderColor: colors.blue,
          backgroundColor: kind === 'bar' ? colors.blue : blueGradient,
          borderWidth: 2.5, tension: .35, fill: kind !== 'bar', pointRadius: 2, borderRadius: 5, maxBarThickness: 16 }
      ] },
      options: { responsive: true, maintainAspectRatio: false, interaction: { mode: 'index', intersect: false },
        scales: { x: { grid: { display: false }, ticks: { color: '#93a2b9', maxRotation: 0, autoSkip: true, maxTicksLimit: 9, font: { size: 10 } } },
          y: { beginAtZero: true, grid: { color: '#edf1f7' }, border: { display: false }, ticks: { color: '#9ba9bc', maxTicksLimit: 5, callback: value => unit === 'triệu' ? `${vi2.format(value)} tr` : fmt(value), font: { size: 10 } } } },
        plugins: { legend: { display: false }, tooltip: { callbacks: { label: item => `${item.dataset.label}: ${vi2.format(item.parsed.y)}${unit ? ` ${unit}` : ''}` } } } }
    });
  }

  function currentPair() {
    return catalog.pairs.find(pair => pair.candidateRunId === runId || pair.baselineRunId === runId) || catalog.pairs[0];
  }

  function createCanvasIn(grid, id) {
    if (!grid) return;
    grid.classList.remove('empty-chart-grid');
    grid.classList.add('chart-canvas-wrap');
    grid.replaceChildren();
    const canvas = document.createElement('canvas');
    canvas.id = id;
    grid.append(canvas);
  }

  function renderProductionList(rows) {
    const root = el('dashboardProduction');
    if (!root) return;
    root.replaceChildren();
    if (!rows.length) { root.textContent = 'Chưa có hoạt động sản xuất trong lượt này.'; return; }
    rows.slice(0, 4).forEach(row => {
      const item = document.createElement('div');
      item.className = 'production-item';
      const title = document.createElement('strong'); title.textContent = row.productName;
      const qty = document.createElement('span'); qty.textContent = `${fmt(row.startedQty)} đơn vị`;
      const date = document.createElement('small'); date.textContent = `Bắt đầu ${shortDate(row.startAt)}`;
      item.append(title, qty, date);
      root.append(item);
    });
  }

  async function renderDashboard() {
    const result = await getRun(runId);
    const m = result.metrics;
    metric('finishedStock', fmt(result.inventory.find(x => x.label === 'Thành phẩm')?.value));
    metric('pendingOrders', fmt(m.endingBacklogQty));
    metric('onTimeRate', percent(m.onTimeUnitRate));
    metric('lostSales', fmt(m.lostQty));
    donut('inventoryDonut', result.inventory);
    donut('orderDonut', result.orders);
    renderProductionList(result.production);
    const note = document.querySelector('.section-note');
    if (note) note.textContent = 'Dữ liệu theo kịch bản đang chọn';

    const pair = currentPair();
    if (pair) {
      const comparison = await getComparison(pair.candidateRunId, 18);
      const periods = [...new Set(comparison.monthly.map(x => x.monthKey))].sort();
      const base = Object.fromEntries(comparison.monthly.filter(x => x.runId === pair.baselineRunId).map(x => [x.monthKey, x]));
      const candidate = Object.fromEntries(comparison.monthly.filter(x => x.runId === pair.candidateRunId).map(x => [x.monthKey, x]));
      createCanvasIn(document.querySelector('#dashboardTrend'), 'dashboardTrendCanvas');
      seriesChart('dashboardTrendCanvas', periods.map(monthLabel), periods.map(k => base[k]?.lostQty ?? 0), periods.map(k => candidate[k]?.lostQty ?? 0), 'line');
    }
  }

  function ensureMiniCharts() {
    if (el('deliveredChart')) return;
    const row = document.querySelector('.operations-donut')?.closest('.row.g-3.g-xl-4.mb-4');
    if (!row) return;
    const container = document.createElement('div');
    container.className = 'row g-3 g-xl-4 mb-4 mini-charts';
    container.innerHTML = [
      ['deliveredChart', 'Lượng giao được', 'Đơn vị đã giao'],
      ['stockChart', 'Tồn bình quân', 'Đơn vị trong kho'],
      ['valueChart', 'Giá trị tồn bình quân', 'Triệu']
    ].map(([id, title, subtitle]) => `<div class="col-lg-4"><article class="surface panel h-100"><div class="panel-heading"><div><span class="section-kicker">${subtitle.toUpperCase()}</span><h3>${title}</h3></div></div><div class="chart-canvas-wrap"><canvas id="${id}"></canvas></div></article></div>`).join('');
    row.after(container);
  }

  function aggregate(rows) {
    const days = rows.reduce((sum, row) => sum + Number(row.dayCount), 0);
    return {
      lost: rows.reduce((sum, row) => sum + Number(row.lostQty), 0),
      delivered: rows.reduce((sum, row) => sum + Number(row.deliveredQty), 0),
      orders: rows.reduce((sum, row) => sum + Number(row.filledOrderCount), 0),
      due: rows.reduce((sum, row) => sum + Number(row.dueOrderCount), 0),
      onTime: rows.reduce((sum, row) => sum + Number(row.onTimeOrderCount), 0),
      stock: days ? rows.reduce((sum, row) => sum + Number(row.avgOnHandQty) * Number(row.dayCount), 0) / days : 0,
      value: days ? rows.reduce((sum, row) => sum + Number(row.avgInventoryValue) * Number(row.dayCount), 0) / days : 0
    };
  }

  function renderComparisonCards(base, candidate) {
    const fields = [
      ['overviewLostSales', candidate.lost, base.lost, false, 'đơn vị'],
      ['deliveredUnits', candidate.delivered, base.delivered, true, 'đơn vị'],
      ['deliveredOrders', candidate.orders, base.orders, true, 'đơn'],
      ['averageStock', candidate.stock, base.stock, false, 'đơn vị'],
      ['averageValue', candidate.value / 1000000, base.value / 1000000, false, 'triệu']
    ];
    for (const [id, value, baseline, higherGood, unit] of fields) {
      const node = document.querySelector(`[data-metric="${id}"]`);
      if (!node) continue;
      node.textContent = unit === 'triệu' ? vi2.format(value) : fmt(value);
      const delta = baseline ? (value - baseline) / baseline * 100 : 0;
      const foot = node.parentElement.querySelector('small');
      foot.textContent = `ROP ${unit === 'triệu' ? vi2.format(baseline) : fmt(baseline)} · ${delta >= 0 ? '+' : ''}${vi2.format(delta)}%`;
      foot.className = (higherGood ? delta >= 0 : delta <= 0) ? 'delta-good' : 'delta-bad';
    }
  }

  function renderMonthlyTable(base, candidate, periods) {
    const body = el('monthlyRows');
    if (!body) return;
    const table = body.closest('table');
    table.classList.add('comparison-table');
    table.querySelector('thead').innerHTML = '<tr><th rowspan="2">Kỳ</th><th rowspan="2">Đến hạn</th><th colspan="2">Lost sales</th><th colspan="2">Đơn giao được</th><th colspan="2">Giao được (đơn vị)</th><th colspan="2">Tồn bình quân</th><th colspan="2">Giá trị tồn (triệu)</th></tr><tr><th>ROP</th><th>Adapt</th><th>ROP</th><th>Adapt</th><th>ROP</th><th>Adapt</th><th>ROP</th><th>Adapt</th><th>ROP</th><th>Adapt</th></tr>';
    body.replaceChildren();
    periods.forEach(key => {
      const b = base[key] || {}, c = candidate[key] || {};
      const values = [monthLabel(key), fmt(c.dueOrderCount || b.dueOrderCount), fmt(b.lostQty), fmt(c.lostQty),
        fmt(b.filledOrderCount), fmt(c.filledOrderCount), fmt(b.deliveredQty), fmt(c.deliveredQty),
        fmt(b.avgOnHandQty), fmt(c.avgOnHandQty), money(b.avgInventoryValue), money(c.avgInventoryValue)];
      const tr = body.insertRow();
      values.forEach(value => { const td = tr.insertCell(); td.textContent = value; });
    });
  }

  function renderRecommendations(base, candidate, fromMonth, toMonth) {
    const root = el('recommendations');
    root.replaceChildren();
    const list = document.createElement('ul');
    const add = text => { const li = document.createElement('li'); li.textContent = text; list.append(li); };
    add(`Giai đoạn ${monthLabel(fromMonth)}–${monthLabel(toMonth)}: lượt Adapt giao ${fmt(candidate.delivered)} đơn vị; lượt ROP giao ${fmt(base.delivered)} đơn vị.`);
    add(`Lost sales của Adapt là ${fmt(candidate.lost)} đơn vị, so với ${fmt(base.lost)} đơn vị của ROP.`);
    add(`Tồn bình quân lần lượt ${fmt(candidate.stock)} và ${fmt(base.stock)} đơn vị; giá trị tồn bình quân ${money(candidate.value)} và ${money(base.value)} triệu.`);
    add('Chênh lệch giữa hai chính sách giúp xác định mức tồn kho phù hợp với mục tiêu giao hàng.');
    root.append(list);
  }

  async function renderOperations() {
    const pair = catalog.pairs.find(item => item.candidateRunId === Number(el('compareRule').value));
    if (!pair) return;
    const months = Number(el('period').value);
    const comparison = await getComparison(pair.candidateRunId, months);
    const periods = [...new Set(comparison.monthly.map(row => row.monthKey))].sort();
    const baseRows = comparison.monthly.filter(row => row.runId === pair.baselineRunId);
    const candidateRows = comparison.monthly.filter(row => row.runId === pair.candidateRunId);
    const base = Object.fromEntries(baseRows.map(row => [row.monthKey, row]));
    const candidate = Object.fromEntries(candidateRows.map(row => [row.monthKey, row]));
    const baseTotal = aggregate(baseRows), candidateTotal = aggregate(candidateRows);
    renderComparisonCards(baseTotal, candidateTotal);
    donut('deliveryDonut', [
      { label: 'Đúng hạn', value: candidateTotal.onTime },
      { label: 'Giao trễ', value: Math.max(0, candidateTotal.orders - candidateTotal.onTime) },
      { label: 'Mất đơn', value: Math.max(0, candidateTotal.due - candidateTotal.orders) }
    ]);
    createCanvasIn(document.querySelector('.empty-chart-grid.tall'), 'lostChart');
    ensureMiniCharts();
    const values = (source, field, divisor = 1) => periods.map(key => Number(source[key]?.[field] || 0) / divisor);
    const labels = periods.map(monthLabel);
    seriesChart('lostChart', labels, values(base, 'lostQty'), values(candidate, 'lostQty'), 'line');
    seriesChart('deliveredChart', labels, values(base, 'deliveredQty'), values(candidate, 'deliveredQty'), 'bar');
    seriesChart('stockChart', labels, values(base, 'avgOnHandQty'), values(candidate, 'avgOnHandQty'), 'line');
    seriesChart('valueChart', labels, values(base, 'avgInventoryValue', 1000000), values(candidate, 'avgInventoryValue', 1000000), 'line', 'triệu');
    renderMonthlyTable(base, candidate, periods);
    renderRecommendations(baseTotal, candidateTotal, comparison.fromMonth, comparison.toMonth);
  }

  function setupOperations() {
    const period = el('period');
    period.replaceChildren();
    [[18, '18 tháng cuối'], [12, '12 tháng cuối'], [24, '24 tháng cuối'], [36, '36 tháng cuối'], [0, 'Toàn giai đoạn']]
      .forEach(([value, label]) => period.add(new Option(label, value)));
    const rules = el('compareRule');
    rules.replaceChildren();
    catalog.pairs.forEach(pair => rules.add(new Option(pair.deliveryRule, pair.candidateRunId)));
    rules.value = String(currentPair()?.candidateRunId || '');
    el('comparePolicy').value = 'rop-adapt';
    period.addEventListener('change', () => renderOperations().catch(error => showError(error.message)));
    rules.addEventListener('change', () => renderOperations().catch(error => showError(error.message)));
    document.querySelectorAll('.period-switch [data-period]').forEach(button => button.addEventListener('click', () => {
      document.querySelectorAll('.period-switch [data-period]').forEach(item => {
        const active = item === button;
        item.classList.toggle('active', active);
        item.setAttribute('aria-pressed', String(active));
      });
      document.querySelectorAll('[data-period-label]').forEach(item => { item.textContent = button.dataset.period; });
    }));
    el('optimizeButton').addEventListener('click', () => renderOperations().catch(error => showError(error.message)));
    return renderOperations();
  }

  async function init() {
    try {
      const [status, bootstrap] = await Promise.all([api('/api/database/status'), api('/api/dss/bootstrap')]);
      el('connectionLabel').textContent = status.connected ? 'Dữ liệu đã cập nhật' : 'Chưa thể cập nhật dữ liệu';
      el('connectionDot').classList.toggle('connected', Boolean(status.connected));
      if (!status.connected) throw new Error('Kết nối dữ liệu tạm thời gián đoạn. Vui lòng thử lại sau.');
      catalog = bootstrap;
      if (!catalog.runs.length) throw new Error('Chưa có dữ liệu phân tích để hiển thị.');
      const saved = Number(sessionStorage.getItem('dssDemoBaseRun'));
      const allowed = new Set(catalog.pairs.flatMap(pair => [pair.baselineRunId, pair.candidateRunId]));
      runId = allowed.has(saved) ? saved : catalog.defaultRunId;
      if (!runId) throw new Error('Chưa có kịch bản nền ROP mất đơn tại hạn giao.');
      const runSelect = el('runSelect');
      catalog.runs.filter(run => allowed.has(run.id)).forEach(run => {
        const pair = catalog.pairs.find(item => item.candidateRunId === run.id || item.baselineRunId === run.id);
        runSelect.add(new Option(`${run.policy === 'ROP' ? 'ROP' : 'Tối ưu'} · ${pair?.deliveryRule || 'Giao nguyên đơn'}`, run.id));
      });
      runSelect.value = String(runId);
      runSelect.addEventListener('change', () => {
        runId = Number(runSelect.value);
        sessionStorage.setItem('dssDemoBaseRun', String(runId));
        if (page === 'dashboard') renderDashboard().catch(error => showError(error.message));
        if (page === 'operations') {
          el('compareRule').value = String(currentPair()?.candidateRunId || '');
          renderOperations().catch(error => showError(error.message));
        }
        if (page === 'orders') location.reload();
      });
      if (page === 'dashboard') await renderDashboard();
      if (page === 'orders') await window.startOrderReplay({catalog, runId, api});
      if (page === 'operations') await setupOperations();
    } catch (error) { showError(error.message); }
  }

  document.querySelectorAll('[data-open-tab]').forEach(button => button.addEventListener('click', () => {
    location.href = button.dataset.openTab === '#nav-order' ? '/Orders' : '/Operations';
  }));
  init();
})();
