"""Two completion conventions with material-ready starts in both; legacy files stay immutable."""
LEGACY='LEGACY_REQUEST_DATE'
ACTUAL='ACTUAL_START_DATE'

def mode(spec):
    value=spec.get('production_lead_time_mode',LEGACY)
    if value not in (LEGACY,ACTUAL):raise ValueError('Invalid production_lead_time_mode')
    return value

def is_start_based(spec):return mode(spec)==ACTUAL

def finish_day(spec,start,requested,lead):
    if lead<1 or int(lead)!=lead:raise ValueError('Production lead must be a positive integer number of days')
    return start+lead if is_start_based(spec) else max(start+1,requested+lead)

def adapt_model(model,meta,data,spec):
    """Relocate production receipts, leaving flow, objective, demand and age balances intact.

    The legacy reduced model may contain an aged start too late to finish under
    the new convention. Set its upper bound to zero; never credit it early or
    discard its pending demand. Keep the original planning-window selection.
    """
    selected=mode(spec)
    if 'production_lead_time_mode' in meta:raise ValueError('Timing extension already applied')
    if selected==LEGACY:
        meta['production_lead_time_mode']=LEGACY
        from .immediate_start import extend
        return extend(model,meta,data,spec)
    inventory_rows={}
    for i,(label,row) in enumerate(zip(model.labels,model.rows)):
        if label!='inventory':continue
        keys=[model.keys[j] for j,c in row.items() if c==1 and model.keys[j][0]=='I']
        if len(keys)!=1:raise ValueError('Unsupported inventory balance structure')
        _,p,k=keys[0];inventory_rows[p,k]=i
    for (kind,p,k,age),j in meta['av'].items():
        if kind!='a':continue
        lead=data['P'][p]['lead_days'];old=k+max(1,lead-age);new=k+lead
        if old==new:continue
        if old<=meta['H']:
            row=model.rows[inventory_rows[p,old]]
            if row.get(j)!=-1:raise ValueError('Missing legacy production receipt coefficient')
            del row[j]
        if new<=meta['H']:model.rows[inventory_rows[p,new]][j]=-1
        else:model.ub[j]=0
    meta['production_lead_time_mode']=ACTUAL
    from .immediate_start import extend
    return extend(model,meta,data,spec)
