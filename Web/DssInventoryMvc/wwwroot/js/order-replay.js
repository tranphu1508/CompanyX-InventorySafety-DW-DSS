'use strict';
window.startOrderReplay = async function ({catalog, runId, api}) {
  runId = catalog.pairs.find(p => p.baselineRunId === runId || p.candidateRunId === runId)?.baselineRunId || runId;
  const $ = id => document.getElementById(id);
  const num = n => n == null ? '—' : Number(n).toLocaleString('vi-VN', {maximumFractionDigits: 2});
  const iso = v => v ? String(v).slice(0, 10) : '';
  const day = v => v ? iso(v).split('-').reverse().join('/') : '—';
  const days = (a, b) => Math.round((Date.parse(iso(a)) - Date.parse(iso(b))) / 86400000);
  const set = (id, value) => { const el = $(id); if (el) el.textContent = value; };
  const request = (action, args) => api('/api/dss/replay/' + action + '?' +
    new URLSearchParams({run: runId, product: $('product').value, ...args}));
  const schedule = document.querySelector('.schedule-placeholder');
  const emptySchedule = schedule.innerHTML;
  const labels = {A: 'Giao đúng hạn', B: 'Hạn giao mới', C: 'Từ chối đơn'};
  let version = 0, active = null, options = [], details = new Map(), selected = null;
  const available = o => o?.dayPlan || (o?.branchRun != null && (o.slot === 'C' || o.orderStatus != null));
  const onTime = o => Boolean(o?.completedAt && iso(o.completedAt) <= iso(o.due));
  const element = (tag, text, className) => {
    const e = document.createElement(tag);
    if (text != null) e.textContent = text;
    if (className) e.className = className;
    return e;
  };
  const candidate = slot => options.find(o => o.candidateId === selected && o.slot === slot) ||
    options.find(o => o.slot === slot && available(o)) || options.find(o => o.slot === slot);
  function status() {
    const outputs = document.querySelectorAll('.status-timeline output');
    const values = [active ? 'Xong' : 'Chờ', $('stock').textContent === '—' ? 'Chờ' : 'Xong',
      options.some(available) ? 'Xong' : 'Chờ', selected && details.has(selected) ? 'Xong' : 'Chờ'];
    outputs.forEach((o, i) => { o.textContent = values[i]; });
  }
  function opening(rows) {
    const first = rows[0], qty = active?.qty;
    set('stock', num(first?.stock)); set('demand', num(qty));
    set('shortage', num(first && qty != null ? Math.max(qty - first.stock, 0) : null));
    set('stockLabel', first?.productName || 'Đơn vị hiện có');
    set('dueLabel', active ? 'Hạn gốc ' + day(active.originalDue) : 'Đơn vị');
    const missing = rows.filter(r => r.missing > 0);
    const complete = first && qty != null && !rows.some(r => r.componentName && r.missing == null);
    set('components', complete ? missing.length + ' mã' : '—');
    const missingNames = missing.map(r => r.componentName + ' (' + num(r.missing) + ')');
    set('componentList', complete && missing.length ?
      missingNames.slice(0, 2).join(', ') + (missing.length > 2 ? '…' : '') :
      'Mã linh kiện tự sản xuất còn thiếu');
    $('componentList').title = missingNames.join(', ');
    status();
  }
  function advice() {
    if (!active) return $('product').value ?
      'Chưa có đơn lớn đã mô phỏng cho mẫu xe và kịch bản này.' :
      'Chọn mẫu xe đạp để xem kết quả đã lưu.';
    if (active.dayPlan) {
      const priority = options.filter(o => o.slot === 'A' && o.planStatus);
      if (priority.length) {
        const feasible = priority.filter(o => o.planStatus === 'OPTIMAL');
        return feasible.length ? 'Đã có kế hoạch ưu tiên đơn mới tại hạn gốc. So sánh A1 và A2 để xem tác động lên các đơn cũ.' :
          'A1 và A2 đều chưa thể giao đủ đơn mới đúng hạn theo ràng buộc vật tư và thời gian sản xuất. Xem phương án B để thương lượng hạn mới.';
      }
      const a = options.find(o => o.slot === 'A');
      const b = options.find(o => o.slot === 'B' && o.plannedShip === active.qty);
      if (a?.plannedShip === active.qty)
        return 'MILP tự chọn giao đủ ' + num(active.qty) + ' xe ngay hạn gốc ' + day(a.due) +
          '. Không cần dời hạn.';
      if (b)
        return 'Tại hạn gốc ' + day(active.originalDue) + ' MILP không chọn giao đủ. ' +
          'Ngày đầu tiên MILP tự chọn giao đủ là ' + day(b.due) +
          ' (+' + days(b.due, active.originalDue) + ' ngày). Đây là phương án đề xuất cho khách.';
      return 'Trong khoảng ngày đã kiểm tra, MILP chưa tự chọn giao đủ đơn này. ' +
        'Có thể mở rộng khoảng tìm kiếm hoặc xem lại cấu hình mô phỏng.';
    }
    const a = options.find(o => o.slot === 'A' && available(o) && onTime(o));
    const b = options.find(o => o.slot === 'B' && available(o) && onTime(o));
    if (a && b) {
      const ia = details.get(a.candidateId)?.impact, ib = details.get(b.candidateId)?.impact;
      const impact = i => i ? num(i.newlyLate) + ' đơn cũ trễ thêm, tồn bình quân xe thay đổi ' +
        num(i.qtyDelta) + ' đơn vị' : 'chưa đủ dữ liệu đối chứng';
      return 'A giao đúng hạn gốc ' + day(a.due) + ' (' + impact(ia) +
        '). B giao theo hạn mới ' + day(b.due) + ' (' + impact(ib) + '), cần khách chấp thuận.';
    }
    if (a) return 'Phương án A giao đủ trước hạn gốc ' + day(a.due) + '.';
    if (b) return 'Phương án B giao đủ trước hạn mới ' + day(b.due) + '; cần khách chấp thuận.';
    return options.some(available) ?
      'Các kết quả đã lưu chưa xác nhận phương án nhận đơn giao đủ đúng hạn.' :
      'Chưa có kết quả phương án đã lưu cho đơn này.';
  }
  function metric(container, label, value) {
    const row = element('span', null, 'scenario-metric');
    row.append(element('span', label), element('output', value));
    container.append(row);
  }
  function cards() {
    set('orderAdvice', advice());
    for (const slot of ['A', 'B', 'C']) {
      const card = document.querySelector('.scenario-card input[value="' + slot + '"]').closest('label');
      const radio = card.querySelector('input'), description = card.querySelector('.scenario-description');
      const body = card.querySelector('.scenario-details'), o = candidate(slot);
      const ready = available(o), impact = details.get(o?.candidateId)?.impact;
      radio.disabled = !ready; radio.checked = ready && selected === o.candidateId;
      body.replaceChildren();
      if (!ready) {
        description.textContent = 'Chưa có kết quả mô phỏng đã lưu';
        continue;
      }
      description.textContent = slot === 'A' ? 'Giữ hạn giao gốc' :
        slot === 'B' ? 'Thương lượng hạn giao với khách' : 'Giữ nguyên kế hoạch hiện tại';
      if (slot === 'B') {
        const alternatives = options.filter(x => x.slot === 'B' && available(x));
        if (alternatives.length > 1) {
          const select = element('select', null, 'form-select replay-deadline');
          select.setAttribute('aria-label', 'Chọn hạn giao mới');
          alternatives.forEach(x => select.add(new Option(day(x.due), x.candidateId)));
          select.value = o.candidateId;
          select.addEventListener('change', e => { selected = e.target.value; render(); });
          body.append(select);
        }
      }
      if (o.dayPlan && o.planStatus) {
        description.textContent = 'Dự kiến theo kế hoạch ngày ' + day(active.knownAt);
        const variants = slot === 'A' ? options.filter(x => x.slot === 'A' && x.planStatus) : [o];
        for (const variant of variants) {
          const section = element('div', null, 'priority-summary');
          section.append(element('strong', variant.variant === 'A1' ? 'A1 · Giữ hạn của các đơn cũ' :
            variant.variant === 'A2' ? 'A2 · Thương lượng lùi đơn cũ' :
            variant.variant === 'B' ? 'B · Giữ đúng hạn toàn bộ đơn cũ' : 'C · Không nhận đơn mới'));
          metric(section, 'Trạng thái', variant.planStatus === 'OPTIMAL' ? 'Có kế hoạch tối ưu' :
            variant.planStatus === 'INFEASIBLE' ? 'Không có phương án khả thi' : 'Chưa giải xong');
          if (variant.planStatus === 'OPTIMAL') {
            if (slot === 'A') metric(section,'Đơn mới giao đúng hạn',num(variant.plannedShip) + ' xe');
            if (slot === 'B') {
              metric(section,'Hạn giao mới',day(variant.due));
              metric(section,'Dời so với hạn gốc','+' + days(variant.due,active.originalDue) + ' ngày');
              metric(section,'Số xe giao đủ',num(variant.plannedShip) + ' xe');
              metric(section,'Cam kết đơn cũ','Giữ đúng hạn toàn bộ');
            }
            const effect = variant.effect;
            if (effect && variant.variant !== 'C') {
              metric(section,'Đơn cũ mất thêm so với C',num(effect.additionalLostOrders) + ' đơn · ' + num(effect.additionalLostUnits) + ' đơn vị');
              if (variant.variant === 'A1') metric(section,'Giá trị hàng mất thêm',num(variant.additionalLostValue));
              metric(section,'Đơn cũ cần lùi',num(effect.delayedOrders));
              metric(section,'Tổng ngày trễ',num(effect.totalLateDays));
              metric(section,'Trễ trung bình / lớn nhất',num(effect.meanLateDays) + ' / ' + num(effect.maxLateDays) + ' ngày');
              metric(section,'Giá trị tồn bình quân tăng',num(effect.inventoryDelta));
              const window = element('small','So với C trong ' + day(effect.evaluationStart) + '–' + day(effect.evaluationEnd));
              section.append(window);
            }
          } else {
            section.append(element('p',variant.explanation || 'Ép giao đúng hạn không tạo được phương án thỏa ràng buộc.'));
          }
          body.append(section);
        }
        if (variants.length > 1) {
          const select = element('select',null,'form-select replay-deadline');
          select.setAttribute('aria-label','Chọn kế hoạch A1 hoặc A2');
          variants.forEach(v=>select.add(new Option('Xem kế hoạch '+v.variant,v.candidateId)));
          select.value=o.candidateId;
          select.addEventListener('change',e=>{selected=e.target.value;render();});
          body.append(select);
        }
        continue;
      }
      if (o.dayPlan) {
        description.textContent = 'Dự kiến tại ngày ' + day(active.knownAt);
        metric(body, 'Hạn giao', day(o.due));
        metric(body, 'MILP tự chọn giao đủ', o.plannedShip === active.qty ? 'Có' : 'Không');
        metric(body, 'Số xe dự kiến giao', num(o.plannedShip));
        metric(body, 'Số xe mất bán dự kiến', num(o.plannedLoss));
        if (slot === 'B') metric(body, 'Dời so với hạn gốc', '+' + days(o.due, active.originalDue) + ' ngày');
        continue;
      }
      metric(body, 'Ngày giao', slot === 'C' ? 'Không giao' :
        day(o.due) + (slot === 'B' ? ' (+' + days(o.due, active.originalDue) + ' ngày)' : ''));
      metric(body, 'Đơn lớn đúng hạn', slot === 'C' ? 'Không' : onTime(o) ? 'Có' : 'Không');
      metric(body, 'Đơn khác bị trễ thêm', impact ?
        num(impact.newlyLate) + ' đơn' +
          (impact.meanLateDays == null ? '' : ' (TB ' + num(impact.meanLateDays) + ' ngày)') : '—');
      metric(body, 'Tồn bình quân của xe đã chọn', impact ?
        num(impact.qtyDelta) + ' đơn vị' +
          (impact.qtyPct == null ? '' : ' (' + num(impact.qtyPct) + '%)') : '—');
      metric(body, 'Giá trị tồn + WIP bình quân', num(impact?.valueDelta));
      if (slot === 'B') metric(body, 'Cần khách đồng ý', 'Có');
      metric(body, 'Mất bán của đơn lớn', slot === 'C' || o.cancelledAt ?
        num(slot === 'C' ? o.declinedQty : active.qty) + ' đơn vị, 1 đơn' : '0');
      if (impact?.unfilledByEnd > 0)
        metric(body, 'Đơn cũ chưa giao đủ cuối kỳ', num(impact.unfilledByEnd) + ' đơn');
    }
  }
  function plan() {
    const o = options.find(x => x.candidateId === selected), detail = details.get(selected);
    set('planTitle', o ? 'Kế hoạch sản xuất cho phương án ' + o.slot + ' (' + labels[o.slot] + ')' :
      'Kế hoạch sản xuất');
    const table = $('productionRows').closest('table');
    table.tHead.rows[0].cells[2].textContent = o?.dayPlan ? 'Số lượng kế hoạch chung' : 'Số lượng cho đơn';
    if (o?.dayPlan) set('planTitle','Phương án ' + o.slot + ' · Kế hoạch sản xuất theo BOM của ' + $('product').selectedOptions[0].textContent);
    const rows = $('productionRows'); rows.replaceChildren();
    const jobs = o?.planStatus === 'INFEASIBLE' ? [] : detail?.plan || [];
    if (!o || !jobs.length) {
      schedule.innerHTML = emptySchedule;
      const note = $('planNote');
      note.textContent = !o ? 'Chọn phương án có kết quả để xem kế hoạch.' :
        o.planStatus === 'INFEASIBLE' ? (o.explanation || 'Phương án không khả thi khi ép giao đủ đúng hạn.') : o.slot === 'C' ? 'Giữ kế hoạch hiện tại; không phát sinh lệnh cho đơn bị từ chối.' :
        o.dayPlan ? 'Kế hoạch không có lệnh khởi công cho xe và các linh kiện liên quan.' : !detail ? 'Đang đọc kế hoạch đã lưu…' :
        'Chưa có công việc sản xuất được phân bổ cho đơn trong phiên bản kế hoạch ngày biết đơn.';
      const tr = rows.insertRow(), td = tr.insertCell();
      td.colSpan = 7; td.className = 'table-empty'; td.textContent = note.textContent;
      status(); return;
    }
    schedule.replaceChildren();
    const gantt = element('div', null, 'replay-schedule');
    const dates = [...jobs.flatMap(j => [j.startDate, j.finishDate]), o.due]
      .filter(Boolean).map(v => Date.parse(iso(v)));
    const lo = Math.min(...dates), hi = Math.max(...dates, lo + 86400000);
    const pct = v => (Date.parse(iso(v)) - lo) * 100 / (hi - lo);
    const dayCount = Math.round((hi - lo) / 86400000);
    gantt.style.setProperty('--replay-track-width', (dayCount * 48) + 'px');
    gantt.style.setProperty('--replay-day-step', (100 / dayCount) + '%');
    const legend = element('div', null, 'replay-legend');
    legend.append(element('i', null, 'replay-due-swatch'),
      element('span', 'Vạch vàng: hạn giao của phương án ' + o.slot + ' · ' + day(o.due)));
    gantt.append(legend);
    const axis = element('div', null, 'replay-axis');
    for (let offset = 0; offset <= dayCount; offset++) {
      const date = new Date(lo + offset * 86400000).toISOString().slice(0, 10);
      const tick = element('span', day(date).slice(0, 5), 'replay-tick');
      tick.style.left = (offset * 100 / dayCount) + '%';
      tick.title = day(date);
      if (iso(o.due) === date) tick.classList.add('replay-tick-due');
      axis.append(tick);
    }
    gantt.append(axis);
    const products = new Map();
    jobs.forEach(job => {
      if (!products.has(job.productId)) products.set(job.productId, []);
      products.get(job.productId).push(job);
    });
    for (const group of products.values()) {
      const item = group[0], level = item.bomLevel ?? 0;
      const line = element('div', null, 'replay-work-row');
      const label = element('span', null, 'replay-bom-label');
      label.style.paddingLeft = (level * 14) + 'px';
      label.title = 'Cấp BOM ' + level + ' · ' + item.name;
      label.append(element('small', 'Cấp ' + level), element('span', item.name));
      const track = element('div', null, 'replay-work-track');
      const lanes = [];
      const production = group.filter(job => job.startDate).sort((a,b) => a.startDate.localeCompare(b.startDate));
      for (const job of production) {
        const start = Date.parse(iso(job.startDate)), finish = Date.parse(iso(job.finishDate || job.startDate));
        let lane = lanes.findIndex(end => end <= start);
        if (lane < 0) lane = lanes.length;
        lanes[lane] = Math.max(start + 86400000, finish);
        const bar = element('i', null, level === 0 ? 'replay-finished' : 'replay-component');
        bar.style.left = pct(job.startDate) + '%';
        bar.style.width = Math.max(0.8, pct(job.finishDate || job.startDate) - pct(job.startDate)) + '%';
        bar.style.top = (5 + lane * 18) + 'px';
        bar.title = item.name + ' · ' + num(job.qty) + ' đơn vị · ' + day(job.startDate) + ' – ' + day(job.finishDate);
        track.append(bar);
      }
      track.style.height = Math.max(24, lanes.length * 18 + 8) + 'px';
      if (!production.length) track.append(element('span','Không có khởi công mới','replay-no-start'));
      const due = element('b', null, 'replay-due');
      due.style.left = pct(o.due) + '%';
      due.title = 'Hạn giao phương án ' + o.slot + ': ' + day(o.due);
      track.append(due); line.append(label,track); gantt.append(line);
    }
    schedule.append(gantt); status();
  }
  function render() { cards(); plan(); }
  function reset() {
    active = null; options = []; details.clear(); selected = null;
    opening([]); render();
  }
  async function refresh() {
    const token = ++version;
    reset();
    const product = $('product').value;
    const quantity = $('quantity').valueAsNumber;
    const known = $('receivedDate').value, due = $('dueDate').value;
    if (!product || !Number.isSafeInteger(quantity) || quantity <= 0 || !known || !due || due < known) {
      set('orderAdvice', 'Chọn xe, nhập số lượng nguyên dương và hai ngày hợp lệ để xem phương án đã lưu.');
      return;
    }
    try {
      const planned = await request('day-plans', {qty:quantity, known, due});
      if (token !== version) return;
      if (planned.length) {
        const stock = await request('opening', {date:known, qty:quantity});
        if (token !== version) return;
        active = {qty:quantity, knownAt:known, originalDue:due, dayPlan:true};
        options = planned.map(o => ({...o, candidateId:o.variant || o.slot, dayPlan:true,
          effect:o.impactJson ? JSON.parse(o.impactJson) : null}));
        options.forEach(o => details.set(o.candidateId, {plan:JSON.parse(o.jobs || '[]')}));
        selected = options.find(o => o.slot === 'B' && o.plannedShip === quantity)?.candidateId ||
          options.find(o => o.slot === 'A')?.candidateId || null;
        opening(stock); render(); return;
      }
      const saved = await request('cases', {});
      if (token !== version) return;
      const matches = saved.filter(c => c.qty === quantity && iso(c.knownAt) === known && iso(c.originalDue) === due)
        .sort((a,b) => b.caseKey - a.caseKey);
      for (const match of matches) {
        const args = {caseKey: match.caseKey, qty: quantity};
        const offers = await request('options', args);
        if (token !== version) return;
        if (!offers.some(available)) continue;
        const stock = await request('opening', {date: known, qty: quantity});
        if (token !== version) return;
        active = match; options = offers; opening(stock); render();
        await Promise.all(offers.filter(available).map(async o => {
          const detail = await request('detail', {...args, candidate:o.candidateId});
          if (token === version) { details.set(o.candidateId, detail); render(); }
        }));
        return;
      }
      set('orderAdvice', 'Chưa có kết quả đã lưu khớp với sản phẩm, số lượng, ngày biết đơn và ngày cần giao.');
    } catch (error) {
      if (token === version) set('orderAdvice', 'Không đọc được dữ liệu đã lưu. Vui lòng thử lại.');
      throw error;
    }
  }
  for (const p of catalog.products || [])
    $('product').add(new Option(p.name + ' · ' + p.number, String(p.productId)));
  // The presentation scenario can be opened directly using the URL printed by the batch.
  const demo = new URLSearchParams(window.location.search);
  const demoProduct = demo.get('demoProduct');
  if (demoProduct && Array.from($('product').options).some(x => x.value === demoProduct))
    $('product').value = demoProduct;
  if (demo.has('demoQty')) $('quantity').value = demo.get('demoQty');
  $('receivedDate').value = demo.get('demoKnown') || '2013-07-01';
  if (demo.has('demoDue')) $('dueDate').value = demo.get('demoDue');
  let timer;
  function changed() {
    ++version; reset(); clearTimeout(timer);
    // Do not fetch until the user clicks "Tìm phương án".
  }
  for (const id of ['product','quantity','receivedDate','dueDate'])
    $(id).addEventListener('input', changed);
  document.querySelectorAll('.scenario-card input').forEach(radio =>
    radio.addEventListener('change', () => { selected = candidate(radio.value)?.candidateId || null; render(); }));
  let reading = false;
  const showSearchMessage = message => {
    const node = $('simulationMessage');
    if (node) { node.hidden = false; node.textContent = message; }
  };
  $('orderForm').addEventListener('submit', async e => {
    e.preventDefault(); clearTimeout(timer);
    if (reading) return;
    const product = Number($('product').value);
    const qty = $('quantity').valueAsNumber;
    const known = $('receivedDate').value, due = $('dueDate').value;
    if (!Number.isSafeInteger(qty) || qty <= 0) {
      showSearchMessage('Số lượng cần phải là số nguyên dương.'); return;
    }
    if (qty > 2147483647) { showSearchMessage('Số lượng vượt quá giới hạn hỗ trợ.'); return; }
    const validDate = value => /^\d{4}-\d{2}-\d{2}$/.test(value) &&
      Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0,10) === value;
    const run = catalog.runs.find(r => r.id === runId);
    if (!validDate(known) || !validDate(due) || due < known) {
      showSearchMessage('Hãy nhập ngày hợp lệ. Ngày cần giao phải từ ngày biết đơn trở đi.'); return;
    }
    if (known < '2013-07-01' || (run && (Number(known.replaceAll('-', '')) < run.startKey || Number(due.replaceAll('-', '')) > run.endKey))) {
      showSearchMessage('Hãy nhập ngày hợp lệ trong khoảng mô phỏng từ 01/07/2013 đến hết kịch bản nền.'); return;
    }
    if (!Number.isSafeInteger(product) || !catalog.products.some(p => p.productId === product)) {
      showSearchMessage('Hãy chọn sản phẩm hợp lệ.'); return;
    }
    reading = true;
    const btn = $('searchDeadlineButton');
    const controls = ['product','quantity','receivedDate','dueDate','runSelect'].map($).filter(Boolean);
    controls.forEach(control => control.disabled = true);
    const originalButtonContent = btn ? Array.from(btn.childNodes) : [];
    const startedAt = performance.now();
    let elapsedTimer;
    if (btn) {
      btn.disabled = true;
      btn.setAttribute('aria-busy', 'true');
      const label = element('span');
      label.style.fontVariantNumeric = 'tabular-nums';
      const spinner = element('span', null, 'spinner-border spinner-border-sm ms-2');
      spinner.setAttribute('aria-hidden', 'true');
      btn.replaceChildren(label, spinner);
      const updateElapsed = () => {
        const seconds = Math.floor((performance.now() - startedAt) / 1000);
        label.textContent = 'Đang giải: ' + String(Math.floor(seconds / 60)).padStart(2, '0') +
          ':' + String(seconds % 60).padStart(2, '0');
      };
      updateElapsed();
      elapsedTimer = setInterval(updateElapsed, 250);
    }
    showSearchMessage('Đang đọc phương án đã mô phỏng từ SIM warehouse…');
    try {
      await refresh();
      if (!options.some(available)) {
        const response = await fetch('/api/dss/replay/search-day', {
          method: 'POST', headers: {'Content-Type':'application/json',
            'RequestVerificationToken': document.querySelector('input[name="__RequestVerificationToken"]').value},
          body: JSON.stringify({run:runId, product, qty, known, due})
        });
        let job = await response.json();
        if (!response.ok) throw new Error(job.message || 'Không thể yêu cầu chạy bộ giải.');
        while (job.state === 'queued' || job.state === 'running') {
          showSearchMessage(job.message);
          await new Promise(resolve => setTimeout(resolve, 2000));
          job = await api('/api/dss/replay/search-day/' + encodeURIComponent(job.id));
        }
        if (job.state !== 'done') throw new Error(job.message || 'Bộ giải chưa hoàn tất.');
        showSearchMessage(job.message);
        // The status response contains no plan. Read the published warehouse again.
        await refresh();
        if (!options.some(available)) throw new Error('Chưa đọc được kết quả đã công bố trong SIM warehouse.');
      }
      const a = options.find(o => o.slot === 'A' && available(o));
      const b = options.find(o => o.slot === 'B' && available(o));
      if (b?.dayPlan && b.plannedShip === qty && b.plannedLoss === 0)
        showSearchMessage('Đã tải phương án B từ SIM warehouse: ' + day(b.due) + '.');
      else if (a?.dayPlan && a.plannedShip === qty && a.plannedLoss === 0)
        showSearchMessage('Đã tải phương án A: giao đủ ngay hạn gốc ' + day(a.due) + '.');
      else if (options.some(available))
        showSearchMessage('Đã tải các phương án có sẵn trong SIM warehouse.');
      else
        showSearchMessage(`SIM warehouse chưa có kết quả cho đơn này.`);
    } catch (error) {
      showSearchMessage('Chưa thể hoàn tất tìm phương án: ' + (error.message || String(error)));
    } finally {
      reading = false;
      controls.forEach(control => control.disabled = false);
      clearInterval(elapsedTimer);
      if (btn) {
        btn.replaceChildren(...originalButtonContent);
        btn.removeAttribute('aria-busy');
        btn.disabled = false;
      }
    }
  });
  refresh().catch(() => {});
};
