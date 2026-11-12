/* Nexus — UI Components v1.2 */
const Components = {
    icons: { shield:'🛡️','user-minus':'👤','file-text':'📄',phone:'📞',box:'📦',terminal:'⌨️',settings:'⚙️',database:'🗄️',cloud:'☁️',lock:'🔒',mail:'📧',chart:'📊',folder:'📁',tool:'🔧',globe:'🌐',key:'🔑' },
    getIcon(n) { return this.icons[n]||this.icons.box; },
    // Server-supplied status strings never go into class attributes directly — they map
    // to a fixed set of class names.
    statusClass(s) { s=String(s||'').toLowerCase(); return ['healthy','missing','unknown','error'].includes(s)?s:'unknown'; },
    healthClass(s) { s=String(s||'').toLowerCase(); return ['healthy','degraded','unavailable'].includes(s)?s:'unknown'; },
    streamClass(s) { s=String(s||'success').toLowerCase(); return ['success','error','warning','info','information','verbose','debug'].includes(s)?s:'info'; },
    sourceBadge(source) {
        const s=(source||'custom').toLowerCase();
        return s==='published'?'<span class="source-badge published" title="PSGallery / PSModulePath">Published</span>':'<span class="source-badge custom" title="Custom module">Custom</span>';
    },
    // Navigation targets are data-nav attributes handled by App.handleClick — never
    // inline handlers with interpolated values, which JS-escape rather than HTML-escape.
    navTarget(...parts) { return this.esc('#/' + parts.map(p => encodeURIComponent(p)).join('/')); },
    moduleCard(mod) {
        const icon=this.getIcon(mod.icon), tags=(mod.tags||[]).map(t=>`<span class="tag">${this.esc(t)}</span>`).join(''), status=this.statusClass(mod.status), source=this.sourceBadge(mod.source);
        return `<div class="module-card" role="button" tabindex="0" data-nav="${this.navTarget('modules',mod.name)}">
            <div class="module-card-header"><div class="module-icon">${icon}</div><h3>${this.esc(mod.name)}</h3>${source}<span class="status-dot ${status}" title="${this.esc(status)}"></span></div>
            <p>${this.esc(mod.description||'No description')}</p><div class="module-tags">${tags}</div>
            <div class="module-card-footer"><span>v${this.esc(mod.version||'?')} · ${this.esc(mod.category||'Uncategorised')}</span>
            ${mod.entryCommand?`<button class="btn btn-sm btn-primary" data-nav="${this.navTarget('commands',mod.name,mod.entryCommand)}">Launch ▶</button>`:''}</div></div>`;
    },
    groupHeader(title,count) { return `<div class="group-header"><h2>${this.esc(title)}</h2><span class="group-count">${this.esc(count)}</span></div>`; },
    commandRow(cmd) {
        const pc=(cmd.parameters||[]).length;
        return `<tr><td><a class="cmd-name" href="${this.navTarget('commands',cmd.module,cmd.name)}">${this.esc(cmd.name)}</a></td><td>${this.esc(cmd.module)}</td><td>${this.esc(cmd.category||'-')}</td><td>${this.esc(cmd.type)}</td><td>${pc}</td></tr>`;
    },
    // Parameters whose values must never be remembered: by name, or by credential type.
    isSensitiveParam(param) { const n=String(param.name||''); return /password|passphrase|secret|token|key|credential|connectionstring|pwd/i.test(n) || /(^|[^a-z])(pass|pin|sas)([^a-z]|$)/i.test(n) || /[a-z0-9](Pass|Pin|Sas)(?![a-z])/.test(n) || /SecureString|PSCredential/i.test(String(param.type||'')); },
    parameterField(param, saved) {
        const pn=this.esc(param.name), pt=this.esc(param.type), id=`param-${pn}`;
        const req=param.mandatory?'<span class="required" aria-hidden="true">*</span><span class="visually-hidden">(required)</span>':'';
        const tb=`<span class="type-badge">${pt}</span>`;
        const hint=param.helpMessage?`<div class="form-hint" id="${id}-hint">${this.esc(param.helpMessage)}</div>`:'';
        const common=`id="${id}" data-param="${pn}"${param.mandatory?' data-mandatory="1" aria-required="true"':''}${this.isSensitiveParam(param)?' data-sensitive="1"':''}${param.helpMessage?` aria-describedby="${id}-hint"`:''}`;
        const has=saved!==undefined&&saved!==null;
        let input;
        if(param.type==='SwitchParameter') input=`<div class="form-check"><input type="checkbox" ${common} data-type="switch"${saved===true?' checked':''}><label for="${id}">Enable</label></div>`;
        else if(param.validateSet&&param.validateSet.length>0) input=`<select class="form-control" ${common} data-type="${pt}"><option value="">-- Select --</option>${param.validateSet.map(v=>`<option value="${this.esc(v)}"${has&&String(saved)===String(v)?' selected':''}>${this.esc(v)}</option>`).join('')}</select>`;
        else input=`<input type="text" class="form-control" ${common} data-type="${pt}" placeholder="${pt}"${has?` value="${this.esc(saved)}"`:''}>`;
        return `<div class="form-group"><label for="${id}">${this.esc(param.name)} ${req} ${tb}</label>${input}${hint}</div>`;
    },
    // Consecutive success records that carry `data` (objects, not text) render as one
    // table; everything else stays a console line. The last output is kept for CSV/JSON export.
    // opts: { truncated, totalCount, error, command }
    outputConsole(output,duration,opts) {
        opts=opts||{};
        const items=Array.isArray(output)?output:[];
        this.lastOutput=items;
        this.lastCommand=opts.command||'output';
        let html='', rows=[];
        const flush=()=>{ if(rows.length){ html+=this.outputTable(rows); rows=[]; } };
        for(const o of items){
            const c=this.streamClass(o.stream);
            if(c==='success'&&o.data&&typeof o.data==='object'){ rows.push(o.data); continue; }
            flush();
            html+=`<div class="console-line ${c}">${this.esc(o.message)}</div>`;
        }
        flush();
        // A failed command can carry output produced before the error — show both.
        if(opts.error){
            const em=String(opts.error);
            if(!items.some(o=>String(o.stream||'').toLowerCase()==='error'&&String(o.message)===em)) html+=`<div class="console-line error">${this.esc(em)}</div>`;
        }
        const n=this.outputRows().length;
        let note='';
        if(opts.truncated===true){
            const total=(opts.totalCount===undefined||opts.totalCount===null)?'':` of ${this.esc(opts.totalCount)}`;
            note=`<div class="console-note" role="note">${total?`Showing ${n}${total} rows`:`Output truncated — showing ${n} rows`}</div>`;
        }
        const dt=duration?` — ${this.esc(duration)}ms`:'';
        const exp=n?'<button class="btn btn-sm" data-action="export-csv">⬇ CSV</button><button class="btn btn-sm" data-action="export-json">⬇ JSON</button>':'';
        return `<div class="console-container"><div class="console-header"><h4>Output${dt}</h4><div class="console-actions">${exp}<button class="btn btn-sm" data-action="copy-output">📋 Copy</button></div></div><div class="console-body" id="consoleBody">${note}${html||'<div class="console-empty">No output yet. Click Run to execute the command.</div>'}</div></div>`;
    },
    outputColumns(rows) { const cols=[]; for(const r of rows) for(const k of Object.keys(r)) if(!cols.includes(k)) cols.push(k); return cols; },
    outputTable(rows) {
        const cols=this.outputColumns(rows), cell=v=>v===null||v===undefined?'':this.esc(v);
        return `<div class="console-table-wrap"><table class="console-table"><thead><tr>${cols.map(c=>`<th>${this.esc(c)}</th>`).join('')}</tr></thead><tbody>${rows.map(r=>`<tr>${cols.map(c=>`<td>${cell(r[c])}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
    },
    outputRows() { return (this.lastOutput||[]).filter(o=>String(o.stream||'success').toLowerCase()==='success'&&o.data&&typeof o.data==='object').map(o=>o.data); },
    download(blob,filename) {
        const url=URL.createObjectURL(blob);
        const a=document.createElement('a'); a.href=url; a.download=filename;
        document.body.appendChild(a); a.click(); a.remove(); setTimeout(()=>URL.revokeObjectURL(url),1000);
    },
    // Quotes every field, and prefixes values Excel would run as a formula — output is
    // tenant data, and a display name of "=HYPERLINK(...)" must stay text.
    exportCsv() {
        const rows=this.outputRows(); if(!rows.length) return;
        const cols=this.outputColumns(rows);
        const field=v=>{ let s=v===null||v===undefined?'':String(v); if(typeof v==='string'&&/^[=+\-@\t\r]/.test(s)) s="'"+s; return '"'+s.replace(/"/g,'""')+'"'; };
        const csv=[cols.map(field).join(','),...rows.map(r=>cols.map(c=>field(r[c])).join(','))].join('\r\n');
        this.download(new Blob(['﻿'+csv],{type:'text/csv;charset=utf-8'}),`nexus-output-${new Date().toISOString().replace(/[:.]/g,'-')}.csv`);
    },
    // <command>-<yyyyMMdd-HHmmss>.json, local time; the command name is made filename-safe.
    exportJson() {
        const rows=this.outputRows(); if(!rows.length) return;
        const d=new Date(), p=n=>String(n).padStart(2,'0');
        const stamp=`${d.getFullYear()}${p(d.getMonth()+1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
        const name=String(this.lastCommand||'output').replace(/[^A-Za-z0-9._-]/g,'_');
        this.download(new Blob([JSON.stringify(rows,null,2)],{type:'application/json;charset=utf-8'}),`${name}-${stamp}.json`);
    },
    copyOutput() {
        const b=document.getElementById('consoleBody'); if(!b) return;
        if(!navigator.clipboard||!navigator.clipboard.writeText){ Components.toast('Copy failed: clipboard unavailable','error'); return; }
        navigator.clipboard.writeText(b.innerText).then(()=>Components.toast('Copied','success')).catch(e=>Components.toast(`Copy failed: ${e&&e.message?e.message:'clipboard blocked'}`,'error'));
    },
    statCard(value,label,colour,iconSvg) { return `<div class="stat-card"><div class="stat-icon ${this.esc(colour)}">${iconSvg}</div><div class="stat-info"><h3>${this.esc(value)}</h3><p>${this.esc(label)}</p></div></div>`; },
    recentItem(item) {
        const time=item.timestamp?new Date(item.timestamp).toLocaleString():'';
        // success is null while an async job is still running or hasn't been polled to completion yet — that's pending, not failed.
        const pending=item.success===null||item.success===undefined, icon=pending?'…':(item.success?'✓':'✗'), cls=pending?'style="color:var(--text-muted)"':(item.success?'style="color:var(--success)"':'style="color:var(--error)"');
        return `<li class="recent-item" role="button" tabindex="0" data-nav="${this.navTarget('commands',item.module,item.command)}"><span ${cls}>${icon}</span><span class="recent-cmd">${this.esc(item.command)}</span><span class="recent-module">${this.esc(item.module)}</span><span class="recent-time">${this.esc(time)}</span></li>`;
    },
    // Sign-in state for a module's live context. A "shared" provider is one whose token
    // is cached for the Windows user, so other modules can silently reuse this sign-in.
    connectionPanel(moduleName, data, failed) {
        if (failed) {
            return `<div class="settings-section" id="connectionPanel"><h3>Session</h3>
                <div class="settings-row"><label>Status</label><span class="value" style="color:var(--text-muted)">Unavailable — could not read session state</span></div></div>`;
        }
        if (!data || !data.active) {
            return `<div class="settings-section" id="connectionPanel"><h3>Session</h3>
                <div class="settings-row"><label>Status</label><span class="value" style="color:var(--text-muted)">No active session — a context starts on first run</span></div></div>`;
        }

        const providers = (data.providers || []).filter(p => p.connected);
        if (providers.length === 0) {
            return `<div class="settings-section" id="connectionPanel"><h3>Session</h3>
                <div class="settings-row"><label>Status</label><span class="value">Context running · not signed in</span></div></div>`;
        }

        const rows = providers.map(p => `<div class="settings-row"><label>${this.esc(p.name)}</label><span class="value">${this.esc(p.account || 'unknown')}${p.tenant ? ` · <span style="color:var(--text-muted)">${this.esc(p.tenant)}</span>` : ''}${p.detail ? ` <span class="tag">${this.esc(p.detail)}</span>` : ''}</span></div>`).join('');
        const shared = providers.some(p => p.shared);
        const hint = shared
            ? `<p style="font-size:12px;color:var(--warning);margin-top:12px">⚠ This sign-in is cached for your Windows user, so other modules can reuse it without prompting. Connect with <code>-ContextScope Process</code> in the module to keep it to one session.</p>`
            : '';

        return `<div class="settings-section" id="connectionPanel"><h3>Session</h3>${rows}${hint}
            <div style="margin-top:16px"><button class="btn btn-danger btn-sm" data-action="disconnect-module" data-module="${this.esc(moduleName)}">Sign out</button></div></div>`;
    },
    favouriteItem(fav) {
        return `<li class="recent-item"><span aria-hidden="true">⭐</span><a class="recent-cmd" href="${this.navTarget('commands',fav.module,fav.command)}">${this.esc(fav.command)}</a><span class="recent-module">${this.esc(fav.module)}</span><button class="btn btn-sm btn-danger" data-action="unfav" data-module="${this.esc(fav.module)}" data-command="${this.esc(fav.command)}" title="Remove favourite" aria-label="Remove favourite ${this.esc(fav.command)}">✕</button></li>`;
    },
    scanRootItem(path) { return `<li class="scan-root-item"><span>📁 ${this.esc(path)}</span><button class="btn btn-sm btn-danger" data-action="remove-scan-root" data-path="${this.esc(path)}" aria-label="Remove scan root ${this.esc(path)}">✕</button></li>`; },
    toast(message,type='info') { const c=document.getElementById('toastContainer'),t=document.createElement('div');t.className=`toast ${['success','error','info','warning'].includes(type)?type:'info'}`;t.textContent=message;c.appendChild(t);setTimeout(()=>{t.classList.add('fade-out');setTimeout(()=>t.remove(),300);},3000); },
    loading() { return '<div class="loading"><div class="spinner"></div> Loading...</div>'; },
    // title/message flow here from URL hash segments and server error text (see
    // renderModuleDetail, renderCommandDetail) — never trust either as markup.
    emptyState(title,message) { return `<div class="empty-state"><svg viewBox="0 0 24 24" width="48" height="48" fill="none" stroke="currentColor" stroke-width="1"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg><h3>${this.esc(title)}</h3><p>${this.esc(message)}</p></div>`; },
    // An explicit failure state with a Retry button; `action` is a data-action name handled by App.
    errorState(title,message,action) { return `<div class="empty-state error-state" role="alert"><svg viewBox="0 0 24 24" width="48" height="48" fill="none" stroke="currentColor" stroke-width="1"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg><h3>${this.esc(title)}</h3><p>${this.esc(message)}</p><button class="btn btn-primary" data-action="${this.esc(action||'retry')}">Retry</button></div>`; },
    breadcrumb(items) { return `<div class="breadcrumb">${items.map((item,i)=>{if(i===items.length-1)return `<span>${this.esc(item.label)}</span>`;return `<a href="${this.esc(item.href)}">${this.esc(item.label)}</a><span class="sep">›</span>`;}).join('')}</div>`; },
    // Escapes quotes as well as angle brackets — textContent/innerHTML leaves quotes
    // intact, which is unsafe inside an attribute value.
    esc(str) { if(str===null||str===undefined)return '';return String(str).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'})[c]); }
};
