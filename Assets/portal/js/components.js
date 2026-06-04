/* Nexus — UI Components v1.1 */
const Components = {
    icons: { shield:'🛡️','user-minus':'👤','file-text':'📄',phone:'📞',box:'📦',terminal:'⌨️',settings:'⚙️',database:'🗄️',cloud:'☁️',lock:'🔒',mail:'📧',chart:'📊',folder:'📁',tool:'🔧',globe:'🌐',key:'🔑' },
    getIcon(n) { return this.icons[n]||this.icons.box; },
    sourceBadge(source) {
        const s=(source||'custom').toLowerCase();
        return s==='published'?'<span class="source-badge published" title="PSGallery / PSModulePath">Published</span>':'<span class="source-badge custom" title="Custom module">Custom</span>';
    },
    moduleCard(mod) {
        const icon=this.getIcon(mod.icon), tags=(mod.tags||[]).map(t=>`<span class="tag">${this.esc(t)}</span>`).join(''), status=mod.status||'unknown', source=this.sourceBadge(mod.source);
        return `<div class="module-card" onclick="App.navigate('#/modules/${encodeURIComponent(mod.name)}')">
            <div class="module-card-header"><div class="module-icon">${icon}</div><h3>${this.esc(mod.name)}</h3>${source}<span class="status-dot ${status}" title="${status}"></span></div>
            <p>${this.esc(mod.description||'No description')}</p><div class="module-tags">${tags}</div>
            <div class="module-card-footer"><span>v${this.esc(mod.version||'?')} · ${this.esc(mod.category||'Uncategorised')}</span>
            ${mod.entryCommand?`<button class="btn btn-sm btn-primary" onclick="event.stopPropagation();App.navigate('#/commands/${encodeURIComponent(mod.name)}/${encodeURIComponent(mod.entryCommand)}')">Launch ▶</button>`:''}</div></div>`;
    },
    groupHeader(title,count) { return `<div class="group-header"><h2>${this.esc(title)}</h2><span class="group-count">${count}</span></div>`; },
    commandRow(cmd) {
        const pc=(cmd.parameters||[]).length;
        return `<tr><td><span class="cmd-name" onclick="App.navigate('#/commands/${encodeURIComponent(cmd.module)}/${encodeURIComponent(cmd.name)}')">${this.esc(cmd.name)}</span></td><td>${this.esc(cmd.module)}</td><td>${this.esc(cmd.category||'-')}</td><td>${this.esc(cmd.type)}</td><td>${pc}</td></tr>`;
    },
    parameterField(param) {
        const req=param.mandatory?'<span class="required">*</span>':'', tb=`<span class="type-badge">${this.esc(param.type)}</span>`, hint=param.helpMessage?`<div class="form-hint">${this.esc(param.helpMessage)}</div>`:'';
        let input;
        if(param.type==='SwitchParameter') input=`<div class="form-check"><input type="checkbox" id="param-${param.name}" data-param="${param.name}" data-type="switch"><label for="param-${param.name}">Enable</label></div>`;
        else if(param.validateSet&&param.validateSet.length>0) input=`<select class="form-control" id="param-${param.name}" data-param="${param.name}" data-type="${param.type}"><option value="">-- Select --</option>${param.validateSet.map(v=>`<option value="${this.esc(v)}">${this.esc(v)}</option>`).join('')}</select>`;
        else input=`<input type="text" class="form-control" id="param-${param.name}" data-param="${param.name}" data-type="${param.type}" placeholder="${param.type}">`;
        return `<div class="form-group"><label>${this.esc(param.name)} ${req} ${tb}</label>${input}${hint}</div>`;
    },
    outputConsole(output,duration) {
        const lines=(output||[]).map(o=>{const c=(o.stream||'success').toLowerCase();return `<div class="console-line ${c}">${this.esc(o.message)}</div>`;}).join('');
        const dt=duration?` — ${duration}ms`:'';
        return `<div class="console-container"><div class="console-header"><h4>Output${dt}</h4><button class="btn btn-sm" onclick="Components.copyOutput()">📋 Copy</button></div><div class="console-body" id="consoleBody">${lines||'<div class="console-empty">No output yet. Click Run to execute the command.</div>'}</div></div>`;
    },
    copyOutput() { const b=document.getElementById('consoleBody');if(b)navigator.clipboard.writeText(b.innerText).then(()=>Components.toast('Copied','success')); },
    statCard(value,label,colour,iconSvg) { return `<div class="stat-card"><div class="stat-icon ${colour}">${iconSvg}</div><div class="stat-info"><h3>${value}</h3><p>${label}</p></div></div>`; },
    recentItem(item) {
        const time=item.timestamp?new Date(item.timestamp).toLocaleString():'', icon=item.success?'✓':'✗', cls=item.success?'style="color:var(--success)"':'style="color:var(--error)"';
        return `<li class="recent-item" onclick="App.navigate('#/commands/${encodeURIComponent(item.module)}/${encodeURIComponent(item.command)}')"><span ${cls}>${icon}</span><span class="recent-cmd">${this.esc(item.command)}</span><span class="recent-module">${this.esc(item.module)}</span><span class="recent-time">${time}</span></li>`;
    },
    scanRootItem(path) { return `<li class="scan-root-item"><span>📁 ${this.esc(path)}</span><button class="btn btn-sm btn-danger" onclick="App.removeScanRoot('${this.esc(path).replace(/'/g,"\\'")}')">✕</button></li>`; },
    toast(message,type='info') { const c=document.getElementById('toastContainer'),t=document.createElement('div');t.className=`toast ${type}`;t.textContent=message;c.appendChild(t);setTimeout(()=>{t.classList.add('fade-out');setTimeout(()=>t.remove(),300);},3000); },
    loading() { return '<div class="loading"><div class="spinner"></div> Loading...</div>'; },
    emptyState(title,message) { return `<div class="empty-state"><svg viewBox="0 0 24 24" width="48" height="48" fill="none" stroke="currentColor" stroke-width="1"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg><h3>${title}</h3><p>${message}</p></div>`; },
    breadcrumb(items) { return `<div class="breadcrumb">${items.map((item,i)=>{if(i===items.length-1)return `<span>${this.esc(item.label)}</span>`;return `<a href="${item.href}">${this.esc(item.label)}</a><span class="sep">›</span>`;}).join('')}</div>`; },
    esc(str) { if(str===null||str===undefined)return '';const d=document.createElement('div');d.textContent=String(str);return d.innerHTML; }
};