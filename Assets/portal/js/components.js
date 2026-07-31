/* Nexus — UI Components v1.1 */
const Components = {
    icons: { shield:'🛡️','user-minus':'👤','file-text':'📄',phone:'📞',box:'📦',terminal:'⌨️',settings:'⚙️',database:'🗄️',cloud:'☁️',lock:'🔒',mail:'📧',chart:'📊',folder:'📁',tool:'🔧',globe:'🌐',key:'🔑' },
    getIcon(n) { return this.icons[n]||this.icons.box; },
    sourceBadge(source) {
        const s=(source||'custom').toLowerCase();
        return s==='published'?'<span class="source-badge published" title="PSGallery / PSModulePath">Published</span>':'<span class="source-badge custom" title="Custom module">Custom</span>';
    },
    // Navigation targets are data-nav attributes handled by App.handleClick — never
    // inline handlers with interpolated values, which JS-escape rather than HTML-escape.
    navTarget(...parts) { return this.esc('#/' + parts.map(p => encodeURIComponent(p)).join('/')); },
    moduleCard(mod) {
        const icon=this.getIcon(mod.icon), tags=(mod.tags||[]).map(t=>`<span class="tag">${this.esc(t)}</span>`).join(''), status=mod.status||'unknown', source=this.sourceBadge(mod.source);
        return `<div class="module-card" data-nav="${this.navTarget('modules',mod.name)}">
            <div class="module-card-header"><div class="module-icon">${icon}</div><h3>${this.esc(mod.name)}</h3>${source}<span class="status-dot ${status}" title="${status}"></span></div>
            <p>${this.esc(mod.description||'No description')}</p><div class="module-tags">${tags}</div>
            <div class="module-card-footer"><span>v${this.esc(mod.version||'?')} · ${this.esc(mod.category||'Uncategorised')}</span>
            ${mod.entryCommand?`<button class="btn btn-sm btn-primary" data-nav="${this.navTarget('commands',mod.name,mod.entryCommand)}">Launch ▶</button>`:''}</div></div>`;
    },
    groupHeader(title,count) { return `<div class="group-header"><h2>${this.esc(title)}</h2><span class="group-count">${count}</span></div>`; },
    commandRow(cmd) {
        const pc=(cmd.parameters||[]).length;
        return `<tr><td><span class="cmd-name" data-nav="${this.navTarget('commands',cmd.module,cmd.name)}">${this.esc(cmd.name)}</span></td><td>${this.esc(cmd.module)}</td><td>${this.esc(cmd.category||'-')}</td><td>${this.esc(cmd.type)}</td><td>${pc}</td></tr>`;
    },
    parameterField(param) {
        const req=param.mandatory?'<span class="required">*</span>':'', tb=`<span class="type-badge">${this.esc(param.type)}</span>`, hint=param.helpMessage?`<div class="form-hint">${this.esc(param.helpMessage)}</div>`:'';
        let input;
        const pn=this.esc(param.name), pt=this.esc(param.type);
        if(param.type==='SwitchParameter') input=`<div class="form-check"><input type="checkbox" id="param-${pn}" data-param="${pn}" data-type="switch"><label for="param-${pn}">Enable</label></div>`;
        else if(param.validateSet&&param.validateSet.length>0) input=`<select class="form-control" id="param-${pn}" data-param="${pn}" data-type="${pt}"><option value="">-- Select --</option>${param.validateSet.map(v=>`<option value="${this.esc(v)}">${this.esc(v)}</option>`).join('')}</select>`;
        else input=`<input type="text" class="form-control" id="param-${pn}" data-param="${pn}" data-type="${pt}" placeholder="${pt}">`;
        return `<div class="form-group"><label>${this.esc(param.name)} ${req} ${tb}</label>${input}${hint}</div>`;
    },
    outputConsole(output,duration) {
        const lines=(output||[]).map(o=>{const c=(o.stream||'success').toLowerCase();return `<div class="console-line ${c}">${this.esc(o.message)}</div>`;}).join('');
        const dt=duration?` — ${duration}ms`:'';
        return `<div class="console-container"><div class="console-header"><h4>Output${dt}</h4><button class="btn btn-sm" data-action="copy-output">📋 Copy</button></div><div class="console-body" id="consoleBody">${lines||'<div class="console-empty">No output yet. Click Run to execute the command.</div>'}</div></div>`;
    },
    copyOutput() { const b=document.getElementById('consoleBody');if(b)navigator.clipboard.writeText(b.innerText).then(()=>Components.toast('Copied','success')); },
    statCard(value,label,colour,iconSvg) { return `<div class="stat-card"><div class="stat-icon ${colour}">${iconSvg}</div><div class="stat-info"><h3>${value}</h3><p>${label}</p></div></div>`; },
    recentItem(item) {
        const time=item.timestamp?new Date(item.timestamp).toLocaleString():'';
        // success is null while an async job is still running or hasn't been polled to completion yet — that's pending, not failed.
        const pending=item.success===null||item.success===undefined, icon=pending?'…':(item.success?'✓':'✗'), cls=pending?'style="color:var(--text-muted)"':(item.success?'style="color:var(--success)"':'style="color:var(--error)"');
        return `<li class="recent-item" data-nav="${this.navTarget('commands',item.module,item.command)}"><span ${cls}>${icon}</span><span class="recent-cmd">${this.esc(item.command)}</span><span class="recent-module">${this.esc(item.module)}</span><span class="recent-time">${time}</span></li>`;
    },
    // Sign-in state for a module's live context. A "shared" provider is one whose token
    // is cached for the Windows user, so other modules can silently reuse this sign-in.
    connectionPanel(moduleName, data) {
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
        return `<li class="recent-item"><span data-nav="${this.navTarget('commands',fav.module,fav.command)}" style="cursor:pointer">⭐</span><span class="recent-cmd" data-nav="${this.navTarget('commands',fav.module,fav.command)}">${this.esc(fav.command)}</span><span class="recent-module">${this.esc(fav.module)}</span><button class="btn btn-sm btn-danger" data-action="unfav" data-module="${this.esc(fav.module)}" data-command="${this.esc(fav.command)}" title="Remove favourite">✕</button></li>`;
    },
    scanRootItem(path) { return `<li class="scan-root-item"><span>📁 ${this.esc(path)}</span><button class="btn btn-sm btn-danger" data-action="remove-scan-root" data-path="${this.esc(path)}">✕</button></li>`; },
    toast(message,type='info') { const c=document.getElementById('toastContainer'),t=document.createElement('div');t.className=`toast ${type}`;t.textContent=message;c.appendChild(t);setTimeout(()=>{t.classList.add('fade-out');setTimeout(()=>t.remove(),300);},3000); },
    loading() { return '<div class="loading"><div class="spinner"></div> Loading...</div>'; },
    emptyState(title,message) { return `<div class="empty-state"><svg viewBox="0 0 24 24" width="48" height="48" fill="none" stroke="currentColor" stroke-width="1"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg><h3>${title}</h3><p>${message}</p></div>`; },
    breadcrumb(items) { return `<div class="breadcrumb">${items.map((item,i)=>{if(i===items.length-1)return `<span>${this.esc(item.label)}</span>`;return `<a href="${item.href}">${this.esc(item.label)}</a><span class="sep">›</span>`;}).join('')}</div>`; },
    // Escapes quotes as well as angle brackets — textContent/innerHTML leaves quotes
    // intact, which is unsafe inside an attribute value.
    esc(str) { if(str===null||str===undefined)return '';return String(str).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'})[c]); }
};