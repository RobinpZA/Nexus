/* Nexus — Main Application v1.1 */
const App = {
    state: { modules: [], health: null, appVersion: null },
    async init() {
        window.addEventListener('hashchange', () => this.route());
        document.addEventListener('keydown', e => { if((e.ctrlKey||e.metaKey)&&e.key==='k'){e.preventDefault();document.getElementById('globalSearch').focus();} if(e.key==='Escape')document.getElementById('globalSearch').blur(); });
        const si=document.getElementById('globalSearch'); let st;
        si.addEventListener('input',()=>{clearTimeout(st);st=setTimeout(()=>{const q=si.value.trim();if(q.length>0)window.location.hash=`#/commands?search=${encodeURIComponent(q)}`;},400);});
        await this.loadAppVersion();
        await this.loadModules(); await this.loadHealth(); this.route();
    },
    async loadModules() { try { const d=await API.getModules(); this.state.modules=d.modules||[]; document.getElementById('footerModuleCount').textContent=`${this.state.modules.length} modules`; } catch(e){} },
    async loadHealth() { try { this.state.health=await API.getHealth(); const el=document.getElementById('footerHealth'),s=this.state.health.status||'unknown'; el.textContent=s.charAt(0).toUpperCase()+s.slice(1); el.className=`health-badge ${s}`; } catch(e){} },
    async loadAppVersion() {
        try {
            const settings = await API.getSettings();
            const version = settings.hubVersion;
            if (version) {
                this.state.appVersion = version;
                this.applyAppVersion(version);
            }
        } catch (e) {}
    },
    applyAppVersion(version) {
        const navVersion = document.querySelector('.nav-version');
        if (navVersion) navVersion.textContent = `v${version}`;

        const footerVersion = document.querySelector('.footer span');
        if (footerVersion) footerVersion.textContent = `Nexus v${version}`;
    },
    route() {
        const hash=window.location.hash||'#/', content=document.getElementById('content');
        document.querySelectorAll('.nav-link').forEach(l=>{l.classList.remove('active');const h=l.getAttribute('href');if(hash===h||(h!=='#/'&&hash.startsWith(h)))l.classList.add('active');});
        if(hash==='#/'||hash==='#') this.renderDashboard(content);
        else if(hash==='#/modules') this.renderModules(content);
        else if(hash.match(/^#\/modules\/([^/]+)$/)) this.renderModuleDetail(content,decodeURIComponent(hash.match(/^#\/modules\/([^/]+)$/)[1]));
        else if(hash.match(/^#\/commands\/([^/]+)\/([^/?]+)/)){const m=hash.match(/^#\/commands\/([^/]+)\/([^/?]+)/);this.renderCommandDetail(content,decodeURIComponent(m[1]),decodeURIComponent(m[2]));}
        else if(hash.startsWith('#/commands')){const p=new URLSearchParams(hash.split('?')[1]||'');this.renderCommands(content,p.get('search')||'');}
        else if(hash==='#/settings') this.renderSettings(content);
        else content.innerHTML=Components.emptyState('Not Found','Page does not exist.');
    },
    navigate(hash) { window.location.hash=hash; },
    groupBySource(modules) { return { custom:modules.filter(m=>(m.source||'custom')==='custom'), published:modules.filter(m=>m.source==='published') }; },

    async renderDashboard(el) {
        el.innerHTML=Components.loading(); await this.loadModules(); await this.loadHealth();
        const mods=this.state.modules, health=this.state.health||{}, healthy=health.healthy||0, total=health.total||mods.length, {custom,published}=this.groupBySource(mods);
        let recentHtml=''; try { const rd=await API.getRecent(); const recent=rd.recent||[]; if(recent.length>0) recentHtml=`<div class="section-title">Recent Commands</div><div class="table-container"><ul class="recent-list">${recent.slice(0,10).map(r=>Components.recentItem(r)).join('')}</ul></div>`; } catch(e){}
        const svgM='<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/></svg>';
        const svgO='<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>';
        const svgC='<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>';
        const svgP='<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>';
        el.innerHTML=`<div class="page-header"><h1>Dashboard</h1><p>Overview of your registered PowerShell modules</p></div>
        <div class="stats-grid">${Components.statCard(total,'Total Modules','blue',svgM)}${Components.statCard(custom.length,'Custom','yellow',svgC)}${Components.statCard(published.length,'Published','green',svgP)}${Components.statCard(healthy,'Healthy','green',svgO)}</div>
        ${recentHtml}
        ${custom.length>0?Components.groupHeader('Custom Modules',custom.length)+`<div class="module-grid">${custom.map(m=>Components.moduleCard(m)).join('')}</div>`:''}
        ${published.length>0?`<div style="margin-top:32px"></div>`+Components.groupHeader('Published Modules',published.length)+`<div class="module-grid">${published.map(m=>Components.moduleCard(m)).join('')}</div>`:''}
        ${mods.length===0?Components.emptyState('No Modules','Go to Settings to configure scan roots.'):''}`;
    },

    async renderModules(el) {
        el.innerHTML=Components.loading(); await this.loadModules();
        const mods=this.state.modules, cats=['All',...new Set(mods.map(m=>m.category).filter(Boolean))];
        el.innerHTML=`<div class="page-header"><h1>Modules</h1><p>Browse and manage your registered PowerShell modules</p></div>
        <div class="filters-bar">
            <input type="text" class="filter-input" id="moduleFilter" placeholder="Filter modules..." oninput="App.filterModules()">
            <select class="filter-select" id="categoryFilter" onchange="App.filterModules()">${cats.map(c=>`<option value="${c}">${c}</option>`).join('')}</select>
            <select class="filter-select" id="sourceFilter" onchange="App.filterModules()"><option value="All">All Sources</option><option value="custom">Custom</option><option value="published">Published</option></select>
            <select class="filter-select" id="groupBySelect" onchange="App.filterModules()"><option value="none">No Grouping</option><option value="source" selected>Group by Source</option><option value="category">Group by Category</option></select>
            <button class="btn" onclick="App.scanRegistry()">🔍 Scan</button>
        </div><div id="moduleGrid"></div>`;
        this.filterModules();
    },
    filterModules() {
        const filter=(document.getElementById('moduleFilter').value||'').toLowerCase(), category=document.getElementById('categoryFilter').value, source=document.getElementById('sourceFilter').value, groupBy=document.getElementById('groupBySelect').value;
        let filtered=this.state.modules;
        if(filter) filtered=filtered.filter(m=>m.name.toLowerCase().includes(filter)||(m.description||'').toLowerCase().includes(filter)||(m.tags||[]).some(t=>t.toLowerCase().includes(filter)));
        if(category&&category!=='All') filtered=filtered.filter(m=>m.category===category);
        if(source&&source!=='All') filtered=filtered.filter(m=>(m.source||'custom')===source);
        const grid=document.getElementById('moduleGrid');
        if(filtered.length===0){grid.innerHTML=Components.emptyState('No Modules Found','No modules match your filter.');return;}
        if(groupBy==='source'){const{custom,published}=this.groupBySource(filtered);let h='';if(custom.length>0)h+=Components.groupHeader('Custom Modules',custom.length)+`<div class="module-grid">${custom.map(m=>Components.moduleCard(m)).join('')}</div>`;if(published.length>0)h+=`<div style="margin-top:24px"></div>`+Components.groupHeader('Published Modules',published.length)+`<div class="module-grid">${published.map(m=>Components.moduleCard(m)).join('')}</div>`;grid.innerHTML=h;}
        else if(groupBy==='category'){const cs=[...new Set(filtered.map(m=>m.category||'Uncategorised'))].sort();let h='';for(const c of cs){const cm=filtered.filter(m=>(m.category||'Uncategorised')===c);h+=Components.groupHeader(c,cm.length)+`<div class="module-grid">${cm.map(m=>Components.moduleCard(m)).join('')}</div><div style="margin-top:24px"></div>`;}grid.innerHTML=h;}
        else grid.innerHTML=`<div class="module-grid">${filtered.map(m=>Components.moduleCard(m)).join('')}</div>`;
    },
    async scanRegistry() { Components.toast('Scanning...','info'); try { const r=await API.scanRegistry(); Components.toast(`Done: ${r.added} added, ${r.updated} updated`,'success'); await this.loadModules(); this.route(); } catch(e) { Components.toast(`Failed: ${e.message}`,'error'); } },

    async renderModuleDetail(el,moduleName) {
        el.innerHTML=Components.loading(); const mod=this.state.modules.find(m=>m.name===moduleName);
        if(!mod){el.innerHTML=Components.emptyState('Not Found',`Module "${moduleName}" not in registry.`);return;}
        let commands=[]; try { const d=await API.getModuleCommands(moduleName); commands=d.commands||[]; } catch(e){}
        const icon=Components.getIcon(mod.icon), tags=(mod.tags||[]).map(t=>`<span class="tag">${Components.esc(t)}</span>`).join(''), deps=(mod.dependencies||[]).map(d=>`<span class="tag">${Components.esc(d)}</span>`).join('')||'<span style="color:var(--text-muted)">None</span>';
        el.innerHTML=`${Components.breadcrumb([{label:'Modules',href:'#/modules'},{label:moduleName}])}
        <div class="page-header"><div style="display:flex;align-items:center;gap:12px"><div class="module-icon" style="font-size:24px">${icon}</div><div><h1>${Components.esc(moduleName)}</h1><p>${Components.esc(mod.description||'')}</p></div>${Components.sourceBadge(mod.source)}<span class="status-dot ${mod.status||'unknown'}"></span></div></div>
        <div class="settings-section"><h3>Module Info</h3>
        <div class="settings-row"><label>Version</label><span class="value">${Components.esc(mod.version)}</span></div>
        <div class="settings-row"><label>Category</label><span class="value">${Components.esc(mod.category)}</span></div>
        <div class="settings-row"><label>Author</label><span class="value">${Components.esc(mod.author)}</span></div>
        <div class="settings-row"><label>Source</label><span class="value">${Components.esc(mod.source||'custom')}</span></div>
        <div class="settings-row"><label>Entry Command</label><span class="value">${Components.esc(mod.entryCommand||'-')}</span></div>
        <div class="settings-row"><label>Tags</label><div class="module-tags">${tags}</div></div>
        <div class="settings-row"><label>Dependencies</label><div class="module-tags">${deps}</div></div></div>
        <div class="section-title">Commands (${commands.length})</div>
        ${commands.length>0?`<div class="table-container"><table><thead><tr><th>Command</th><th>Module</th><th>Category</th><th>Type</th><th>Params</th></tr></thead><tbody>${commands.map(c=>Components.commandRow(c)).join('')}</tbody></table></div>`:Components.emptyState('No Commands','Module does not export commands or could not be imported.')}`;
    },

    async renderCommands(el,sq) {
        el.innerHTML=Components.loading(); let cmds=[]; try { const d=await API.searchCommands(sq); cmds=d.results||[]; } catch(e){}
        el.innerHTML=`<div class="page-header"><h1>Commands</h1><p>Search commands across all modules</p></div>
        <div class="filters-bar"><input type="text" class="filter-input" id="cmdSearchInput" placeholder="Search commands..." value="${Components.esc(sq)}" oninput="App.debounceCommandSearch()"></div>
        ${cmds.length>0?`<div class="table-container"><table><thead><tr><th>Command</th><th>Module</th><th>Category</th><th>Type</th><th>Params</th></tr></thead><tbody>${cmds.map(c=>Components.commandRow(c)).join('')}</tbody></table></div><p style="margin-top:12px;font-size:12px;color:var(--text-muted)">${cmds.length} command(s)</p>`:Components.emptyState('No Commands',sq?`No match for "${sq}".`:'Type a search term.')}`;
    },
    _cst:null, debounceCommandSearch(){clearTimeout(this._cst);this._cst=setTimeout(()=>{const q=document.getElementById('cmdSearchInput').value.trim();window.location.hash=q?`#/commands?search=${encodeURIComponent(q)}`:'#/commands';},400);},

    async renderCommandDetail(el,mn,cn) {
        el.innerHTML=Components.loading(); let pd; try { pd=await API.getCommandParams(mn,cn); } catch(e){el.innerHTML=Components.emptyState('Not Found',`Cannot load ${cn}.`);return;}
        const params=pd.parameters||[];
        el.innerHTML=`${Components.breadcrumb([{label:'Modules',href:'#/modules'},{label:mn,href:'#/modules/'+encodeURIComponent(mn)},{label:cn}])}
        <div class="cmd-detail-header"><h1>${Components.esc(cn)}</h1></div>
        <div class="cmd-meta"><span>Module: <strong>${Components.esc(mn)}</strong></span><span>Parameters: <strong>${params.length}</strong></span></div>
        ${pd.synopsis?`<p style="color:var(--text-secondary);margin-bottom:24px">${Components.esc(pd.synopsis)}</p>`:''}
        ${params.length>0?`<div class="param-section"><h3>Parameters</h3>${params.map(p=>Components.parameterField(p)).join('')}</div>`:''}
        <div class="run-bar"><button class="btn btn-primary" id="runBtn" onclick="App.runCommand('${mn}','${cn}')">▶ Run Command</button><button class="btn" onclick="App.addFavourite('${mn}','${cn}')">⭐ Favourite</button><span class="run-status" id="runStatus"></span></div>
        <div id="outputArea">${Components.outputConsole(null)}</div>`;
    },
    async runCommand(mn,cn) {
        const btn=document.getElementById('runBtn'),status=document.getElementById('runStatus'),oa=document.getElementById('outputArea'),params={};
        document.querySelectorAll('[data-param]').forEach(i=>{const n=i.dataset.param,t=i.dataset.type;if(t==='switch'){if(i.checked)params[n]=true;}else{const v=i.value.trim();if(v)params[n]=v;}});
        btn.disabled=true;btn.textContent='⏳ Running...';status.textContent='Executing...';status.className='run-status running';
        try{const r=await API.executeCommand(mn,cn,params);oa.innerHTML=Components.outputConsole(r.output,r.durationMs);if(r.success){status.textContent=`✓ ${r.durationMs}ms`;status.style.color='var(--success)';Components.toast('Success','success');}else{status.textContent=`✗ Failed`;status.style.color='var(--error)';Components.toast('Failed','error');}}
        catch(e){oa.innerHTML=Components.outputConsole([{stream:'Error',message:e.message}]);status.textContent=`✗ ${e.message}`;status.style.color='var(--error)';}
        finally{btn.disabled=false;btn.textContent='▶ Run Command';}
    },
    async addFavourite(mn,cn){try{await API.addFavourite(mn,cn);Components.toast(`Added ${cn}`,'success');}catch(e){Components.toast(e.message,'error');}},

    async renderSettings(el) {
        el.innerHTML=Components.loading(); let settings={}; try{settings=await API.getSettings();}catch(e){}
        if (settings.hubVersion) {
            this.state.appVersion = settings.hubVersion;
            this.applyAppVersion(settings.hubVersion);
        }
        const hubVersion = settings.hubVersion || this.state.appVersion || 'Unknown';
        const sr=(settings.scanRoots||[]).map(r=>Components.scanRootItem(r)).join(''), pc=settings.scanPublishedModules?'checked':'';
        el.innerHTML=`<div class="page-header"><h1>Settings</h1><p>Nexus configuration and registry management</p></div>
        <div class="settings-section"><h3>Server</h3>
        <div class="settings-row"><label>Default Port</label><span class="value">${settings.defaultPort||8090}</span></div>
        <div class="settings-row"><label>Port Range</label><span class="value">${(settings.portRange||[]).join(' – ')}</span></div>
        <div class="settings-row"><label>Open Browser on Start</label><span class="value">${settings.openBrowserOnStart?'Yes':'No'}</span></div>
        <div class="settings-row"><label>Log Level</label><span class="value">${settings.logLevel||'Info'}</span></div></div>
        <div class="settings-section"><h3>Custom Module Scanning</h3>
        <div class="settings-row"><label>Scan on Startup</label><span class="value">${settings.scanOnStartup?'Yes':'No'}</span></div>
        <div class="settings-row"><label>Scan Depth</label><span class="value">${settings.scanDepth||2}</span></div>
        <div style="margin-top:16px"><label style="font-size:13px;color:var(--text-secondary);display:block;margin-bottom:8px">Scan Roots</label>
        <ul class="scan-root-list" id="scanRootList">${sr||'<li style="color:var(--text-muted);padding:8px">No scan roots configured</li>'}</ul></div>
        <div style="margin-top:12px;display:flex;gap:8px;align-items:center"><input type="text" class="form-control" id="newScanRoot" placeholder="C:\\Path\\To\\Modules" style="flex:1"><button class="btn btn-primary" onclick="App.addScanRoot()">+ Add Path</button></div>
        <div style="margin-top:20px"><button class="btn btn-primary" onclick="App.scanRegistry()">🔍 Scan Now</button></div></div>
        <div class="settings-section"><h3>Published Module Scanning</h3>
        <p style="font-size:13px;color:var(--text-secondary);margin-bottom:16px">Enable to discover modules installed from the PowerShell Gallery (PSModulePath).</p>
        <div class="settings-row"><label>Include Published Modules</label><div class="form-check" style="margin:0"><input type="checkbox" id="publishedToggle" ${pc} onchange="App.togglePublished()"><label for="publishedToggle">${settings.scanPublishedModules?'Enabled':'Disabled'}</label></div></div></div>
        <div class="settings-section"><h3>Registry</h3>
        <div class="settings-row"><label>Registered Modules</label><span class="value">${this.state.modules.length}</span></div>
        <div class="settings-row"><label>Custom</label><span class="value">${this.state.modules.filter(m=>(m.source||'custom')==='custom').length}</span></div>
        <div class="settings-row"><label>Published</label><span class="value">${this.state.modules.filter(m=>m.source==='published').length}</span></div>
        <div class="settings-row"><label>Health</label><span class="health-badge ${(this.state.health||{}).status||'unknown'}">${((this.state.health||{}).status||'unknown')}</span></div></div>
        <div class="settings-section"><h3>About</h3><div class="settings-row"><label>Version</label><span class="value">${Components.esc(hubVersion)}</span></div><div class="settings-row"><label>Author</label><span class="value">Robin Pieterse</span></div><div class="settings-row"><label>Company</label><span class="value">Turrito Networks</span></div></div>`;
    },
    async addScanRoot(){const i=document.getElementById('newScanRoot'),p=i.value.trim();if(!p){Components.toast('Enter a path','warning');return;}try{await API._fetch('/api/settings/scanroots',{method:'POST',body:JSON.stringify({path:p})});Components.toast(`Added: ${p}`,'success');i.value='';this.renderSettings(document.getElementById('content'));}catch(e){Components.toast(e.message,'error');}},
    async removeScanRoot(path){try{await API._fetch('/api/settings/scanroots',{method:'DELETE',body:JSON.stringify({path})});Components.toast(`Removed`,'success');this.renderSettings(document.getElementById('content'));}catch(e){Components.toast(e.message,'error');}},
    async togglePublished(){const en=document.getElementById('publishedToggle').checked;try{await API._fetch('/api/settings/published',{method:'POST',body:JSON.stringify({enabled:en})});Components.toast(`Published scanning ${en?'enabled':'disabled'}`,'success');const l=document.querySelector('#publishedToggle + label');if(l)l.textContent=en?'Enabled':'Disabled';}catch(e){Components.toast(e.message,'error');}},
    async shutdown(){if(!confirm('Stop Nexus?'))return;try{await API.shutdown();}catch(e){}document.getElementById('content').innerHTML=Components.emptyState('Nexus Stopped','Server shut down. Close this tab.');}
};
document.addEventListener('DOMContentLoaded',()=>App.init());

// ── Override renderModuleDetail to use categorized commands ──
const _origRenderModuleDetail = App.renderModuleDetail.bind(App);
App.renderModuleDetail = async function(el, moduleName, preloadedData) {
    el.innerHTML = Components.loading();
    const mod = this.state.modules.find(m => m.name === moduleName);
    if (!mod) { el.innerHTML = Components.emptyState('Not Found', `Module "${moduleName}" not in registry.`); return; }

    let data = preloadedData;
    if (!data) {
        try { data = await API.getModuleCommands(moduleName); } catch(e) { data = { commands: [], categories: [], quickStart: { connection: [], primary: [] } }; }
    }

    const commands = data.commands || [];
    const categories = data.categories || [];
    const quickStart = data.quickStart || { connection: [], primary: [] };
    const icon = Components.getIcon(mod.icon);
    const tags = (mod.tags || []).map(t => `<span class="tag">${Components.esc(t)}</span>`).join('');
    const deps = (mod.dependencies || []).map(d => `<span class="tag">${Components.esc(d)}</span>`).join('') || '<span style="color:var(--text-muted)">None</span>';

    el.innerHTML = `${Components.breadcrumb([{label:'Modules',href:'#/modules'},{label:moduleName}])}
    <div class="page-header"><div style="display:flex;align-items:center;gap:12px">
        <div class="module-icon" style="font-size:24px">${icon}</div>
        <div><h1>${Components.esc(moduleName)}</h1><p>${Components.esc(mod.description||'')}</p></div>
        ${Components.sourceBadge(mod.source)}<span class="status-dot ${mod.status||'unknown'}"></span>
    </div></div>

    ${CommandsUI.quickStartPanel(quickStart, moduleName)}

    <div class="settings-section"><h3>Module Info</h3>
        <div class="settings-row"><label>Version</label><span class="value">${Components.esc(mod.version)}</span></div>
        <div class="settings-row"><label>Category</label><span class="value">${Components.esc(mod.category)}</span></div>
        <div class="settings-row"><label>Author</label><span class="value">${Components.esc(mod.author)}</span></div>
        <div class="settings-row"><label>Source</label><span class="value">${Components.esc(mod.source||'custom')}</span></div>
        <div class="settings-row"><label>Tags</label><div class="module-tags">${tags}</div></div>
        <div class="settings-row"><label>Dependencies</label><div class="module-tags">${deps}</div></div>
    </div>

    <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:16px">
        <div class="section-title" style="margin:0">Commands (${commands.length})</div>
        ${CommandsUI.loadDescriptionsButton(moduleName)}
    </div>

    ${categories.length > 0
        ? CommandsUI.categorizedCommands(categories, moduleName)
        : (commands.length > 0
            ? '<div class="table-container"><table><thead><tr><th>Command</th><th>Module</th><th>Category</th><th>Type</th><th>Params</th></tr></thead><tbody>' + commands.map(c => Components.commandRow(c)).join('') + '</tbody></table></div>'
            : Components.emptyState('No Commands', 'Module does not export commands.')
        )
    }`;
};

// ── Smart Sync/Async Command Execution ──
App.runCommand = async function(mn, cn) {
    const btn = document.getElementById('runBtn');
    const status = document.getElementById('runStatus');
    const oa = document.getElementById('outputArea');

    const params = {};
    document.querySelectorAll('[data-param]').forEach(i => {
        const n = i.dataset.param, t = i.dataset.type;
        if (t === 'switch') { if (i.checked) params[n] = true; }
        else { const v = i.value.trim(); if (v) params[n] = v; }
    });

    btn.disabled = true;
    btn.textContent = '⏳ Running...';
    status.textContent = 'Executing...';
    status.className = 'run-status running';
    status.style.color = '';

    try {
        const response = await API.executeCommand(mn, cn, params);

        if (response.mode === 'sync' || response.output) {
            // ── Synchronous result (connection commands) ──
            oa.innerHTML = Components.outputConsole(response.output, response.durationMs);
            if (response.success) {
                status.textContent = `✓ Connected (${response.durationMs}ms)`;
                status.style.color = 'var(--success)';
                Components.toast('Success', 'success');
            } else {
                status.textContent = '✗ Failed';
                status.style.color = 'var(--error)';
                Components.toast('Failed', 'error');
            }
        } else if (response.mode === 'async' && response.jobId) {
            // ── Async: poll for results ──
            status.textContent = 'Running in background...';
            const result = await App.pollJob(response.jobId, status, oa);
            if (result) {
                oa.innerHTML = Components.outputConsole(result.output, result.durationMs);
                if (result.success) {
                    status.textContent = `✓ Completed (${result.durationMs}ms)`;
                    status.style.color = 'var(--success)';
                    Components.toast('Success', 'success');
                } else {
                    status.textContent = '✗ Failed';
                    status.style.color = 'var(--error)';
                    Components.toast('Failed', 'error');
                }
            }
        } else {
            // Unknown response shape — show raw
            oa.innerHTML = Components.outputConsole([{stream:'Info', message: JSON.stringify(response)}]);
        }
    } catch (e) {
        oa.innerHTML = Components.outputConsole([{ stream: 'Error', message: e.message }]);
        status.textContent = `✗ ${e.message}`;
        status.style.color = 'var(--error)';
    } finally {
        btn.disabled = false;
        btn.textContent = '▶ Run Command';
    }
};

App.pollJob = async function(jobId, statusEl, outputEl) {
    let polls = 0;
    const maxPoll = 600;  // 10 min timeout

    while (polls < maxPoll) {
        await new Promise(r => setTimeout(r, 1000));
        polls++;

        try {
            const data = await API._fetch(`/api/jobs/${jobId}`);

            if (data.status === 'running') {
                if (statusEl) statusEl.textContent = `Running... ${data.elapsed || polls}s`;
                continue;
            }

            // Completed or failed
            return data;
        } catch (e) {
            if (polls > 5) {
                return { success: false, output: [{ stream: 'Error', message: `Lost connection to job: ${e.message}` }], durationMs: 0 };
            }
        }
    }
    return { success: false, output: [{ stream: 'Error', message: 'Job timed out (10 min)' }], durationMs: 0 };
};
