'use strict';
window.startOrderReplay = async function ({catalog, runId, api}) {
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
    if (active.dayPlan) return 'Theo kế hoạch ngày ' + day(active.knownAt) + ', ' +
      options.map(o => o.slot + ' dự kiến giao ' + num(o.plannedShip) + '/' + num(active.qty) + ' xe ngày ' + day(o.due)).join('; ') + '.';
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
      if (o.dayPlan) {
        description.textContent = 'Dự kiến tại ngày ' + day(active.knownAt);
        metric(body, 'Hạn giao', day(o.due));
        metric(body, 'Dự kiến giao đủ', o.plannedShip === active.qty ? 'Có' : 'Không');
        metric(body, 'Số xe dự kiến giao', num(o.plannedShip));
        metric(body, 'Số xe mất bán dự kiến', num(o.plannedLoss));
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
    if (o?.dayPlan) set('planTitle','Phương án ' + o.slot + ' · Kế hoạch sản xuất xe và linh kiện cho tất cả đơn đã biết');
    const rows = $('productionRows'); rows.replaceChildren();
    const jobs = detail?.plan || [];
    if (!o || !jobs.length) {
      schedule.innerHTML = emptySchedule;
      const note = $('planNote');
      note.textContent = !o ? 'Chọn phương án có kết quả để xem kế hoạch.' :
        o.slot === 'C' ? 'Giữ kế hoạch hiện tại; không phát sinh lệnh cho đơn bị từ chối.' :
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
    const axis = element('div', null, 'replay-axis');
    axis.append(element('span', day(new Date(lo).toISOString())));
    axis.append(element('span', 'Hạn giao ' + day(o.due)));
    gantt.append(axis);
    jobs.forEach((j, i) => {
      const line = element('div', null, 'replay-work-row');
      const track = element('div', null, 'replay-work-track');
      const bar = element('i', null, Number($('product').value) === j.productId ?
        'replay-finished' : 'replay-component');
      bar.style.left = pct(j.startDate) + '%';
      bar.style.width = Math.max(0.8, pct(j.finishDate || j.startDate) - pct(j.startDate)) + '%';
      const due = element('b', null, 'replay-due'); due.style.left = pct(o.due) + '%';
      track.append(bar, due); line.append(element('span', j.name), track); gantt.append(line);
      const tr = rows.insertRow();
      [i + 1, j.name, num(j.qty), day(j.releaseDate), day(j.startDate),
        day(j.finishDate), j.finishDate ? days(j.finishDate, j.startDate) : '—',
        j.productId].forEach((v, k) => { if (k !== 7) tr.insertCell().textContent = v; });
    });
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
        options = planned.map(o => ({...o, candidateId:o.slot, dayPlan:true}));
        options.forEach(o => details.set(o.slot, {plan:JSON.parse(o.jobs || '[]')}));
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
    } catch {
      if (token === version) set('orderAdvice', 'Không đọc được dữ liệu đã lưu. Vui lòng thử lại.');
    }
  }
  for (const p of catalog.products || [])
    $('product').add(new Option(p.name + ' · ' + p.number, String(p.productId)));
  $('receivedDate').value = '2013-07-01';
  let timer;
  function changed() {
    ++version; reset(); clearTimeout(timer);
    timer = setTimeout(refresh, 200);
  }
  for (const id of ['product','quantity','receivedDate','dueDate'])
    $(id).addEventListener('input', changed);
  document.querySelectorAll('.scenario-card input').forEach(radio =>
    radio.addEventListener('change', () => { selected = candidate(radio.value)?.candidateId || null; render(); }));
  $('orderForm').addEventListener('submit', e => { e.preventDefault(); clearTimeout(timer); refresh(); });
  refresh();
};
