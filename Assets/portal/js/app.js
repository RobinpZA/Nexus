/* Nexus — Main Application v1.2 */
const App = {
    state: { modules: [], health: null, appVersion: null, modulesFailed: false, connectionCommands: {} },
    // Incremented on every navigation; async renders compare against it after each await
    // and bail out when the user has already moved on.
    renderToken: 0,
    // The async job started from the current command page, if any: { id, stopped, cancelled, cancelling }.
    activeJob: null,
    async init() {
        window.addEventListener('hashchange', () => this.route());
        document.addEventListener('click', e => this.handleClick(e));
        document.addEventListener('input', e => {
            const t=e.target.closest('[data-on-input]'); if(t) this.handleInput(t.dataset.onInput);
            const f=e.target.closest('[aria-invalid="true"]'); if(f){ f.removeAttribute('aria-invalid'); f.classList.remove('invalid'); }
        });
        document.addEventListener('change', e => { const t=e.target.closest('[data-on-change]'); if(t) this.handleInput(t.dataset.onChange); });
        document.addEventListener('keydown', e => {
            if((e.ctrlKey||e.metaKey)&&e.key==='k'){e.preventDefault();document.getElementById('globalSearch').focus();}
            if(e.key==='Escape')document.getElementById('globalSearch').blur();
            // Cards and list items that act as buttons: Enter/Space activates the focused element itself.
            if((e.key==='Enter'||e.key===' ')&&e.target instanceof Element&&e.target.matches('[role="button"][data-nav]')){e.preventDefault();this.navigate(e.target.dataset.nav);}
        });
        const si=document.getElementById('globalSearch'); let st;
        si.addEventListener('input',()=>{clearTimeout(st);st=setTimeout(()=>{const q=si.value.trim();if(q.length>0)window.location.hash=`#/commands?search=${encodeURIComponent(q)}`;},400);});
        await this.loadAppVersion();
        await this.loadModules(); await this.loadHealth(); this.route();
    },
    async loadModules() {
        const el=document.getElementById('footerModuleCount');
        try { const d=await API.getModules(); this.state.modules=d.modules||[]; this.state.modulesFailed=false; el.textContent=`${this.state.modules.length} modules`; return true; }
        catch(e){ this.state.modulesFailed=true; el.textContent='Modules unavailable'; return false; }
    },
    async loadHealth() {
        const el=document.getElementById('footerHealth');
        try { this.state.health=await API.getHealth(); const s=String(this.state.health.status||'unknown'); el.textContent=s.charAt(0).toUpperCase()+s.slice(1); el.className=`health-badge ${Components.healthClass(s)}`; return true; }
        catch(e){ this.state.health=null; el.textContent='Unavailable'; el.className='health-badge unavailable'; return false; }
    },
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
    // ── UI-convenience storage (never holds tokens; every access is guarded) ──
    storageGet(key) { try { return window.localStorage.getItem(key); } catch(e) { return null; } },
    storageSet(key, value) { try { window.localStorage.setItem(key, value); } catch(e) {} },
    storageRemove(key) { try { window.localStorage.removeItem(key); } catch(e) {} },
    paramsKey(mn, cn) { return `nexus.params.${mn}|${cn}`; },
    loadSavedParams(mn, cn) {
        const raw=this.storageGet(this.paramsKey(mn,cn)); if(!raw) return {};
        try { const o=JSON.parse(raw); return o&&typeof o==='object'&&!Array.isArray(o)?o:{}; } catch(e) { return {}; }
    },
    safeDecode(s) { try { return decodeURIComponent(s); } catch(e) { return null; } },

    route() {
        if (API.unauthorised) return;
        this.renderToken++;
        // Leaving a command page stops its poll loop; the job itself keeps running server-side.
        if (this.activeJob) { this.activeJob.stopped = true; this.activeJob = null; }
        const hash=window.location.hash||'#/', content=document.getElementById('content');
        document.querySelectorAll('.nav-link').forEach(l=>{l.classList.remove('active');const h=l.getAttribute('href');if(hash===h||(h!=='#/'&&hash.startsWith(h)))l.classList.add('active');});
        let mm;
        if(hash==='#/'||hash==='#') this.renderDashboard(content);
        else if(hash==='#/modules') this.renderModules(content);
        else if((mm=hash.match(/^#\/modules\/([^/]+)$/))){
            const name=this.safeDecode(mm[1]);
            if(name===null) return this.fallbackHome(content);
            this.renderModuleDetail(content,name);
        }
        else if((mm=hash.match(/^#\/commands\/([^/]+)\/([^/?]+)/))){
            const m=this.safeDecode(mm[1]), c=this.safeDecode(mm[2]);
            if(m===null||c===null) return this.fallbackHome(content);
            this.renderCommandDetail(content,m,c);
        }
        else if(hash.startsWith('#/commands')){const p=new URLSearchParams(hash.split('?')[1]||'');this.renderCommands(content,p.get('search')||'');}
        else if(hash==='#/settings') this.renderSettings(content);
        else content.innerHTML=Components.emptyState('Not Found','Page does not exist.');
    },
    // A malformed hash (bad percent-encoding) lands on the home view instead of throwing.
    fallbackHome(content) {
        try { history.replaceState(null,'','#/'); } catch(e) {}
        document.querySelectorAll('.nav-link').forEach(l=>l.classList.toggle('active',l.getAttribute('href')==='#/'));
        this.renderDashboard(content);
    },
    navigate(hash) { window.location.hash=hash; },
    // Single delegated handler: rendered markup carries data-nav / data-action instead
    // of inline onclick handlers, which cannot safely embed values from the URL or API.
    handleClick(e) {
        const target=e.target instanceof Element?e.target:null;
        if(!target) return;
        const action=target.closest('[data-action]');
        if(action){
            const d=action.dataset;
            switch(d.action){
                case 'run': this.runCommand(d.module,d.command); return;
                case 'cancel-job': this.cancelJob(); return;
                case 'fav-toggle': this.toggleFavourite(action,d.module,d.command); return;
                case 'clear-params': this.clearParams(d.module,d.command); return;
                case 'unfav': this.removeFavourite(d.module,d.command); return;
                case 'clear-recent': this.clearRecent(); return;
                case 'remove-scan-root': this.removeScanRoot(d.path); return;
                case 'add-scan-root': this.addScanRoot(); return;
                case 'load-desc': CommandsUI.fetchDescriptions(d.module); return;
                case 'disconnect-module': this.disconnectModule(d.module); return;
                case 'scan': this.scanRegistry(); return;
                case 'shutdown': this.shutdown(); return;
                case 'copy-output': Components.copyOutput(); return;
                case 'export-csv': Components.exportCsv(); return;
                case 'export-json': Components.exportJson(); return;
                case 'retry': this.retry(); return;
                case 'retry-search': { const i=document.getElementById('cmdSearchInput'); this.loadCommandResults(i?i.value.trim():''); return; }
                case 'toggle-category': { const c=action.closest('.cmd-category'); if(c){ c.classList.toggle('collapsed'); action.setAttribute('aria-expanded',String(!c.classList.contains('collapsed'))); } return; }
            }
        }
        const nav=target.closest('[data-nav]');
        if(nav) this.navigate(nav.dataset.nav);
    },
    // Re-run the current view, re-fetching what the footer shows as well.
    async retry() { await this.loadModules(); await this.loadHealth(); this.route(); },
    handleInput(name){
        switch(name){
            case 'filter-modules': this.filterModules(); return;
            case 'search-commands': this.debounceCommandSearch(); return;
            case 'toggle-published': this.togglePublished(); return;
        }
    },
    groupBySource(modules) { return { custom:modules.filter(m=>(m.source||'custom')==='custom'), published:modules.filter(m=>m.source==='published') }; },

    async renderDashboard(el) {
        const token=this.renderToken;
        el.innerHTML=Components.loading();
        const modulesOk=await this.loadModules(); await this.loadHealth();
        if(token!==this.renderToken) return;
        if(!modulesOk){ el.innerHTML=Components.errorState('Modules unavailable','Could not load the module list from the server.','retry'); return; }
        const mods=this.state.modules, health=this.state.health, healthy=health?(health.healthy||0):'–', total=(health&&health.total)||mods.length, {custom,published}=this.groupBySource(mods);
        let recentHtml=''; try { const rd=await API.getRecent(); const recent=rd.recent||[]; if(recent.length>0) recentHtml=`<div class="section-title" style="display:flex;align-items:center;justify-content:space-between">Recent Commands<button class="btn btn-sm" data-action="clear-recent">Clear</button></div><div class="table-container"><ul class="recent-list">${recent.slice(0,10).map(r=>Components.recentItem(r)).join('')}</ul></div>`; } catch(e){}
        if(token!==this.renderToken) return;
        let favHtml=''; try { const fd=await API.getFavourites(); const favs=fd.favourites||[]; if(favs.length>0) favHtml=`<div class="section-title">Favourites</div><div class="table-container"><ul class="recent-list">${favs.map(f=>Components.favouriteItem(f)).join('')}</ul></div>`; } catch(e){}
        if(token!==this.renderToken) return;
        const svgM='<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/></svg>';
        const svgO='<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>';
        const svgC='<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>';
        const svgP='<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>';
        el.innerHTML=`<div class="page-header"><h1>Dashboard</h1><p>Overview of your registered PowerShell modules</p></div>
        <div class="stats-grid">${Components.statCard(total,'Total Modules','blue',svgM)}${Components.statCard(custom.length,'Custom','yellow',svgC)}${Components.statCard(published.length,'Published','green',svgP)}${Components.statCard(healthy,'Healthy','green',svgO)}</div>
        ${favHtml}
        ${recentHtml}
        ${custom.length>0?Components.groupHeader('Custom Modules',custom.length)+`<div class="module-grid">${custom.map(m=>Components.moduleCard(m)).join('')}</div>`:''}
        ${published.length>0?`<div style="margin-top:32px"></div>`+Components.groupHeader('Published Modules',published.length)+`<div class="module-grid">${published.map(m=>Components.moduleCard(m)).join('')}</div>`:''}
        ${mods.length===0?Components.emptyState('No Modules','Go to Settings to configure scan roots.'):''}`;
    },

    async renderModules(el) {
        const token=this.renderToken;
        el.innerHTML=Components.loading();
        const ok=await this.loadModules();
        if(token!==this.renderToken) return;
        if(!ok){ el.innerHTML=Components.errorState('Modules unavailable','Could not load the module list from the server.','retry'); return; }
        const mods=this.state.modules, cats=['All',...new Set(mods.map(m=>m.category).filter(Boolean))];
        el.innerHTML=`<div class="page-header"><h1>Modules</h1><p>Browse and manage your registered PowerShell modules</p></div>
        <div class="filters-bar">
            <label class="visually-hidden" for="moduleFilter">Filter modules</label>
            <input type="text" class="filter-input" id="moduleFilter" placeholder="Filter modules..." data-on-input="filter-modules">
            <label class="visually-hidden" for="categoryFilter">Category</label>
            <select class="filter-select" id="categoryFilter" data-on-change="filter-modules">${cats.map(c=>`<option value="${Components.esc(c)}">${Components.esc(c)}</option>`).join('')}</select>
            <label class="visually-hidden" for="sourceFilter">Source</label>
            <select class="filter-select" id="sourceFilter" data-on-change="filter-modules"><option value="All">All Sources</option><option value="custom">Custom</option><option value="published">Published</option></select>
            <label class="visually-hidden" for="groupBySelect">Grouping</label>
            <select class="filter-select" id="groupBySelect" data-on-change="filter-modules"><option value="none">No Grouping</option><option value="source" selected>Group by Source</option><option value="category">Group by Category</option></select>
            <button class="btn" data-action="scan">🔍 Scan</button>
        </div><div id="moduleGrid"></div>`;
        this.filterModules();
    },
    filterModules() {
        const grid=document.getElementById('moduleGrid'), fi=document.getElementById('moduleFilter');
        if(!grid||!fi) return;
        const filter=(fi.value||'').toLowerCase(), category=document.getElementById('categoryFilter').value, source=document.getElementById('sourceFilter').value, groupBy=document.getElementById('groupBySelect').value;
        let filtered=this.state.modules;
        if(filter) filtered=filtered.filter(m=>m.name.toLowerCase().includes(filter)||(m.description||'').toLowerCase().includes(filter)||(m.tags||[]).some(t=>t.toLowerCase().includes(filter)));
        if(category&&category!=='All') filtered=filtered.filter(m=>m.category===category);
        if(source&&source!=='All') filtered=filtered.filter(m=>(m.source||'custom')===source);
        if(filtered.length===0){grid.innerHTML=Components.emptyState('No Modules Found','No modules match your filter.');return;}
        if(groupBy==='source'){const{custom,published}=this.groupBySource(filtered);let h='';if(custom.length>0)h+=Components.groupHeader('Custom Modules',custom.length)+`<div class="module-grid">${custom.map(m=>Components.moduleCard(m)).join('')}</div>`;if(published.length>0)h+=`<div style="margin-top:24px"></div>`+Components.groupHeader('Published Modules',published.length)+`<div class="module-grid">${published.map(m=>Components.moduleCard(m)).join('')}</div>`;grid.innerHTML=h;}
        else if(groupBy==='category'){const cs=[...new Set(filtered.map(m=>m.category||'Uncategorised'))].sort();let h='';for(const c of cs){const cm=filtered.filter(m=>(m.category||'Uncategorised')===c);h+=Components.groupHeader(c,cm.length)+`<div class="module-grid">${cm.map(m=>Components.moduleCard(m)).join('')}</div><div style="margin-top:24px"></div>`;}grid.innerHTML=h;}
        else grid.innerHTML=`<div class="module-grid">${filtered.map(m=>Components.moduleCard(m)).join('')}</div>`;
    },
    async scanRegistry() { Components.toast('Scanning...','info'); try { const r=await API.scanRegistry(); Components.toast(`Done: ${r.added} added, ${r.updated} updated`,'success'); await this.loadModules(); this.route(); } catch(e) { Components.toast(`Failed: ${e.message}`,'error'); } },

    // The page shell (including the search input) is rendered once; only #cmdResults is
    // replaced while typing, so the input keeps focus and caret.
    async renderCommands(el,sq) {
        el.innerHTML=`<div class="page-header"><h1>Commands</h1><p>Search commands across all modules</p></div>
        <div class="filters-bar"><label class="visually-hidden" for="cmdSearchInput">Search commands</label><input type="text" class="filter-input" id="cmdSearchInput" placeholder="Search commands..." value="${Components.esc(sq)}" data-on-input="search-commands"></div>
        <div id="cmdResults" aria-live="polite"></div>`;
        await this.loadCommandResults(sq);
    },
    _searchSeq:0,
    async loadCommandResults(sq) {
        const token=this.renderToken, seq=++this._searchSeq, box=document.getElementById('cmdResults');
        if(!box) return;
        box.innerHTML=Components.loading();
        let cmds;
        try { const d=await API.searchCommands(sq); cmds=d.results||[]; }
        catch(e){ if(token!==this.renderToken||seq!==this._searchSeq) return; box.innerHTML=Components.errorState('Search failed',e.message||'Could not load commands.','retry-search'); return; }
        if(token!==this.renderToken||seq!==this._searchSeq) return;
        box.innerHTML=cmds.length>0?`<div class="table-container"><table><thead><tr><th>Command</th><th>Module</th><th>Category</th><th>Type</th><th>Params</th></tr></thead><tbody>${cmds.map(c=>Components.commandRow(c)).join('')}</tbody></table></div><p style="margin-top:12px;font-size:12px;color:var(--text-muted)">${cmds.length} command(s)</p>`:Components.emptyState('No Commands',sq?`No match for "${sq}".`:'No commands are registered.');
    },
    _cst:null, debounceCommandSearch(){
        clearTimeout(this._cst);
        this._cst=setTimeout(()=>{
            const i=document.getElementById('cmdSearchInput'); if(!i) return;
            const q=i.value.trim();
            // replaceState keeps the URL shareable without firing hashchange (which would re-render the input).
            try { history.replaceState(null,'',q?`#/commands?search=${encodeURIComponent(q)}`:'#/commands'); } catch(e) {}
            this.loadCommandResults(q);
        },400);
    },

    async renderCommandDetail(el,mn,cn) {
        const token=this.renderToken;
        el.innerHTML=Components.loading(); let pd; try { pd=await API.getCommandParams(mn,cn); } catch(e){ if(token!==this.renderToken) return; const title=e.status===409?'Busy':e.status===404?'Not Found':'Error';el.innerHTML=Components.emptyState(title,e.message||`Cannot load ${cn}.`);return;}
        if(token!==this.renderToken) return;
        let isFav=false; try { const fd=await API.getFavourites(); isFav=(fd.favourites||[]).some(f=>f.module===mn&&f.command===cn); } catch(e){}
        if(token!==this.renderToken) return;
        const params=pd.parameters||[], saved=this.loadSavedParams(mn,cn);
        el.innerHTML=`${Components.breadcrumb([{label:'Modules',href:'#/modules'},{label:mn,href:'#/modules/'+encodeURIComponent(mn)},{label:cn}])}
        <div class="cmd-detail-header"><h1>${Components.esc(cn)}</h1></div>
        <div class="cmd-meta"><span>Module: <strong>${Components.esc(mn)}</strong></span><span>Parameters: <strong>${params.length}</strong></span></div>
        ${pd.synopsis?`<p style="color:var(--text-secondary);margin-bottom:24px">${Components.esc(pd.synopsis)}</p>`:''}
        ${params.length>0?`<div class="param-section"><h3>Parameters</h3>${params.map(p=>Components.parameterField(p,Components.isSensitiveParam(p)||!Object.prototype.hasOwnProperty.call(saved,p.name)?undefined:saved[p.name])).join('')}<div class="form-message" id="formMessage" role="alert"></div></div>`:''}
        <div class="run-bar"><button class="btn btn-primary" id="runBtn" data-action="run" data-module="${Components.esc(mn)}" data-command="${Components.esc(cn)}">▶ Run Command</button>${this.favButtonHtml(mn,cn,isFav)}${params.length>0?`<button class="btn btn-sm" data-action="clear-params" data-module="${Components.esc(mn)}" data-command="${Components.esc(cn)}" title="Clear the fields and forget the remembered values">Clear</button>`:''}<span class="run-status" id="runStatus" aria-live="polite"></span><button class="btn btn-sm btn-danger" id="cancelBtn" data-action="cancel-job" hidden>✕ Cancel</button></div>
        <div id="outputArea">${Components.outputConsole(null,0,{command:cn})}</div>`;
    },
    refreshFormMessage(text) { const m=document.getElementById('formMessage'); if(m) m.textContent=text||''; },
    clearParams(mn,cn) {
        document.querySelectorAll('[data-param]').forEach(i=>{
            if(i.dataset.type==='switch') i.checked=false; else i.value='';
            i.removeAttribute('aria-invalid'); i.classList.remove('invalid');
        });
        this.refreshFormMessage('');
        this.storageRemove(this.paramsKey(mn,cn));
        Components.toast('Parameters cleared','info');
    },
    favButtonHtml(mn,cn,isFav) {
        return `<button class="btn${isFav?' is-active':''}" data-action="fav-toggle" data-module="${Components.esc(mn)}" data-command="${Components.esc(cn)}" aria-pressed="${isFav?'true':'false'}">${isFav?'★ Favourited':'☆ Favourite'}</button>`;
    },
    async toggleFavourite(btn,mn,cn) {
        if(btn.disabled) return;
        const was=btn.getAttribute('aria-pressed')==='true';
        btn.disabled=true;
        try {
            if(was) await API.removeFavourite(mn,cn); else await API.addFavourite(mn,cn);
            btn.setAttribute('aria-pressed',was?'false':'true');
            btn.classList.toggle('is-active',!was);
            btn.textContent=was?'☆ Favourite':'★ Favourited';
            Components.toast(was?`Removed ${cn}`:`Added ${cn}`,'success');
        } catch(e) { Components.toast(e.message,'error'); }
        finally { btn.disabled=false; }
    },
    async refreshConnection(moduleName,token){
        const el=document.getElementById('connectionPanel');
        if(!el) return;
        try{ const data=await API.getModuleConnection(moduleName); if(token!==this.renderToken) return; const cur=document.getElementById('connectionPanel'); if(cur) cur.outerHTML=Components.connectionPanel(moduleName,data); }
        catch(e){ if(token!==this.renderToken) return; const cur=document.getElementById('connectionPanel'); if(cur) cur.outerHTML=Components.connectionPanel(moduleName,null,true); }
    },
    async disconnectModule(moduleName){
        try{
            await API.disconnectModule(moduleName);
            Components.toast('Signed out','success');
            await this.refreshConnection(moduleName,this.renderToken);
        }catch(e){ Components.toast(e.message,'error'); }
    },
    async removeFavourite(mn,cn){try{await API.removeFavourite(mn,cn);Components.toast(`Removed ${cn}`,'success');if(window.location.hash==='#/'||window.location.hash==='#'||!window.location.hash)this.route();}catch(e){Components.toast(e.message,'error');}},
    async clearRecent(){try{await API.clearRecent();Components.toast('Recent commands cleared','success');this.route();}catch(e){Components.toast(e.message,'error');}},

    async renderSettings(el) {
        const token=this.renderToken;
        el.innerHTML=Components.loading(); let settings; try{settings=await API.getSettings();}catch(e){ if(token!==this.renderToken) return; el.innerHTML=Components.errorState('Settings unavailable',e.message||'Could not load settings from the server.','retry'); return; }
        if(token!==this.renderToken) return;
        if (settings.hubVersion) {
            this.state.appVersion = settings.hubVersion;
            this.applyAppVersion(settings.hubVersion);
        }
        const E=Components.esc, show=(v,f)=>E((v===undefined||v===null||v==='')?(f===undefined?'—':f):v), yn=v=>v===undefined||v===null?'—':(v?'Yes':'No');
        const hubVersion = settings.hubVersion || this.state.appVersion || 'Unknown';
        const sr=(settings.scanRoots||[]).map(r=>Components.scanRootItem(r)).join(''), pc=settings.scanPublishedModules?'checked':'';
        const hs=this.state.health?String(this.state.health.status||'unknown'):'unavailable';
        el.innerHTML=`<div class="page-header"><h1>Settings</h1><p>Nexus configuration and registry management</p></div>
        <div class="settings-section"><h3>Server</h3>
        <div class="settings-row"><label>Default Port</label><span class="value">${show(settings.defaultPort)}</span></div>
        <div class="settings-row"><label>Port Range</label><span class="value">${Array.isArray(settings.portRange)&&settings.portRange.length?E(settings.portRange.join(' – ')):'—'}</span></div>
        <div class="settings-row"><label>Open Browser on Start</label><span class="value">${yn(settings.openBrowserOnStart)}</span></div>
        <div class="settings-row"><label>Log Level</label><span class="value">${show(settings.logLevel)}</span></div></div>
        <div class="settings-section"><h3>Custom Module Scanning</h3>
        <div class="settings-row"><label>Scan on Startup</label><span class="value">${yn(settings.scanOnStartup)}</span></div>
        <div class="settings-row"><label>Scan Depth</label><span class="value">${show(settings.scanDepth)}</span></div>
        <div style="margin-top:16px"><label style="font-size:13px;color:var(--text-secondary);display:block;margin-bottom:8px">Scan Roots</label>
        <ul class="scan-root-list" id="scanRootList">${sr||'<li style="color:var(--text-muted);padding:8px">No scan roots configured</li>'}</ul></div>
        <div style="margin-top:12px;display:flex;gap:8px;align-items:center"><label class="visually-hidden" for="newScanRoot">New scan root path</label><input type="text" class="form-control" id="newScanRoot" placeholder="C:\\Path\\To\\Modules" style="flex:1"><button class="btn btn-primary" data-action="add-scan-root">+ Add Path</button></div>
        <div style="margin-top:20px"><button class="btn btn-primary" data-action="scan">🔍 Scan Now</button></div></div>
        <div class="settings-section"><h3>Published Module Scanning</h3>
        <p style="font-size:13px;color:var(--text-secondary);margin-bottom:16px">Enable to discover modules installed from the PowerShell Gallery (PSModulePath).</p>
        <div class="settings-row"><label>Include Published Modules</label><div class="form-check" style="margin:0"><input type="checkbox" id="publishedToggle" ${pc} data-on-change="toggle-published"><label for="publishedToggle">${settings.scanPublishedModules?'Enabled':'Disabled'}</label></div></div></div>
        <div class="settings-section"><h3>Registry</h3>
        <div class="settings-row"><label>Registered Modules</label><span class="value">${this.state.modules.length}</span></div>
        <div class="settings-row"><label>Custom</label><span class="value">${this.state.modules.filter(m=>(m.source||'custom')==='custom').length}</span></div>
        <div class="settings-row"><label>Published</label><span class="value">${this.state.modules.filter(m=>m.source==='published').length}</span></div>
        <div class="settings-row"><label>Health</label><span class="health-badge ${Components.healthClass(hs)}">${E(hs)}</span></div></div>
        <div class="settings-section"><h3>About</h3><div class="settings-row"><label>Version</label><span class="value">${E(hubVersion)}</span></div><div class="settings-row"><label>Author</label><span class="value">Robin Pieterse</span></div></div>`;
    },
    async addScanRoot(){const i=document.getElementById('newScanRoot'),p=i.value.trim();if(!p){Components.toast('Enter a path','warning');return;}try{await API._fetch('/api/settings/scanroots',{method:'POST',body:JSON.stringify({path:p})});Components.toast(`Added: ${p}`,'success');i.value='';this.renderSettings(document.getElementById('content'));}catch(e){Components.toast(e.message,'error');}},
    async removeScanRoot(path){try{await API._fetch('/api/settings/scanroots',{method:'DELETE',body:JSON.stringify({path})});Components.toast(`Removed`,'success');this.renderSettings(document.getElementById('content'));}catch(e){Components.toast(e.message,'error');}},
    async togglePublished(){const en=document.getElementById('publishedToggle').checked;try{await API._fetch('/api/settings/published',{method:'POST',body:JSON.stringify({enabled:en})});Components.toast(`Published scanning ${en?'enabled':'disabled'}`,'success');const l=document.querySelector('#publishedToggle + label');if(l)l.textContent=en?'Enabled':'Disabled';}catch(e){Components.toast(e.message,'error');}},
    async shutdown(){if(!confirm('Stop Nexus?'))return;try{await API.shutdown();}catch(e){}document.getElementById('content').innerHTML=Components.emptyState('Nexus Stopped','Server shut down. Close this tab.');}
};
document.addEventListener('DOMContentLoaded',()=>App.init());

// ── Module detail: categorized commands + quick start ──
App.renderModuleDetail = async function(el, moduleName, preloadedData) {
    const token = this.renderToken;
    el.innerHTML = Components.loading();
    const mod = this.state.modules.find(m => m.name === moduleName);
    if (!mod) { el.innerHTML = Components.emptyState('Not Found', `Module "${moduleName}" not in registry.`); return; }

    let data = preloadedData;
    if (!data) {
        try { data = await API.getModuleCommands(moduleName); }
        catch(e) {
            if (token !== this.renderToken) return;
            el.innerHTML = Components.errorState('Commands unavailable', e.message || `Could not load commands for ${moduleName}.`, 'retry');
            return;
        }
        if (token !== this.renderToken) return;
    }

    const commands = data.commands || [];
    const categories = data.categories || [];
    const quickStart = data.quickStart || { connection: [], primary: [] };
    this.state.connectionCommands[moduleName] = quickStart.connection || [];
    const icon = Components.getIcon(mod.icon);
    const tags = (mod.tags || []).map(t => `<span class="tag">${Components.esc(t)}</span>`).join('');
    const deps = (mod.dependencies || []).map(d => `<span class="tag">${Components.esc(d)}</span>`).join('') || '<span style="color:var(--text-muted)">None</span>';
    const dot = Components.statusClass(mod.status);

    el.innerHTML = `${Components.breadcrumb([{label:'Modules',href:'#/modules'},{label:moduleName}])}
    <div class="page-header"><div style="display:flex;align-items:center;gap:12px">
        <div class="module-icon" style="font-size:24px">${icon}</div>
        <div><h1>${Components.esc(moduleName)}</h1><p>${Components.esc(mod.description||'')}</p></div>
        ${Components.sourceBadge(mod.source)}<span class="status-dot ${dot}" title="${Components.esc(dot)}"></span>
    </div></div>

    ${CommandsUI.quickStartPanel(quickStart, moduleName)}

    ${Components.connectionPanel(moduleName, null)}

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

    // Filled in after the page renders — it queries the module's live context.
    this.refreshConnection(moduleName, token);
};

// ── Smart Sync/Async Command Execution ──
App.isConnectCommand = function(mn, cn) {
    return /^Connect-/i.test(cn) || (this.state.connectionCommands[mn] || []).includes(cn);
};

// Renders a finished result (sync response or finished/cancelled job) into the page.
App.showResult = function(ctx, result) {
    const { status, oa, mn, cn } = ctx;
    oa.innerHTML = Components.outputConsole(result.output, result.durationMs, {
        truncated: result.truncated === true,
        totalCount: result.totalCount,
        error: result.error,
        command: cn
    });
    const ms = result.durationMs ? ` (${result.durationMs}ms)` : '';
    if (result.status === 'cancelled') {
        status.textContent = '⏹ Cancelled';
        status.style.color = 'var(--warning)';
        Components.toast('Cancelled', 'warning');
    } else if (result.success) {
        status.textContent = `✓ ${this.isConnectCommand(mn, cn) ? 'Connected' : 'Completed'}${ms}`;
        status.style.color = 'var(--success)';
        Components.toast('Success', 'success');
    } else {
        status.textContent = '✗ Failed';
        status.style.color = 'var(--error)';
        Components.toast('Failed', 'error');
    }
};

App.runCommand = async function(mn, cn) {
    const btn = document.getElementById('runBtn');
    const status = document.getElementById('runStatus');
    const oa = document.getElementById('outputArea');
    const cancelBtn = document.getElementById('cancelBtn');
    if (!btn || !status || !oa || btn.disabled) return;
    const token = this.renderToken;

    // Gather values and validate mandatory ones before anything is sent.
    const params = {}, toSave = {}, missing = [];
    document.querySelectorAll('[data-param]').forEach(i => {
        i.removeAttribute('aria-invalid'); i.classList.remove('invalid');
        const n = i.dataset.param, t = i.dataset.type;
        if (t === 'switch') { if (i.checked) { params[n] = true; if (!i.dataset.sensitive) toSave[n] = true; } }
        else {
            const v = i.value.trim();
            if (v) { params[n] = v; if (!i.dataset.sensitive) toSave[n] = v; }
            else if (i.dataset.mandatory) missing.push(i);
        }
    });
    if (missing.length > 0) {
        missing.forEach(i => { i.setAttribute('aria-invalid', 'true'); i.classList.add('invalid'); });
        this.refreshFormMessage(`Required: ${missing.map(i => i.dataset.param).join(', ')}`);
        missing[0].focus();
        return;
    }
    this.refreshFormMessage('');
    // Remember the last-used values; sensitive parameters are never in toSave.
    if (Object.keys(toSave).length > 0) this.storageSet(this.paramsKey(mn, cn), JSON.stringify(toSave));
    else this.storageRemove(this.paramsKey(mn, cn));

    const ctx = { status, oa, mn, cn };
    let job = null;

    btn.disabled = true;
    btn.textContent = '⏳ Running...';
    status.textContent = 'Executing...';
    status.className = 'run-status running';
    status.style.color = '';

    try {
        const response = await API.executeCommand(mn, cn, params);
        if (token !== this.renderToken) return;

        if (response.mode === 'sync' || response.output) {
            // ── Synchronous result ──
            status.className = 'run-status';
            this.showResult(ctx, response);
        } else if (response.mode === 'async' && response.jobId) {
            // ── Async: poll for results ──
            job = { id: response.jobId, stopped: false, cancelled: false, cancelling: false };
            this.activeJob = job;
            if (cancelBtn) { cancelBtn.hidden = false; cancelBtn.disabled = false; }
            status.textContent = 'Running in background...';
            let result = await this.pollJob(job, status);
            if (token !== this.renderToken) return;
            if (!result && job.cancelled) {
                // Cancelled: fetch whatever output the job captured before it stopped.
                try { result = await API.getJob(job.id); }
                catch (e) { result = { status: 'cancelled', output: [], durationMs: 0 }; }
                if (token !== this.renderToken) return;
                result.status = 'cancelled';
            }
            status.className = 'run-status';
            if (result) this.showResult(ctx, result);
        } else {
            // Unknown response shape — show raw
            status.className = 'run-status';
            oa.innerHTML = Components.outputConsole([{stream:'Info', message: JSON.stringify(response)}], 0, { command: cn });
            status.textContent = '';
        }
    } catch (e) {
        if (token !== this.renderToken) return;
        oa.innerHTML = Components.outputConsole([{ stream: 'Error', message: e.message }], 0, { command: cn });
        status.className = 'run-status';
        status.textContent = `✗ ${e.message}`;
        status.style.color = 'var(--error)';
    } finally {
        if (job && this.activeJob === job) this.activeJob = null;
        if (token === this.renderToken) {
            if (cancelBtn) { cancelBtn.hidden = true; cancelBtn.disabled = false; }
            btn.disabled = false;
            btn.textContent = '▶ Run Command';
        }
    }
};

// DELETE the running job. The poll loop (in runCommand) notices the flags, stops, and
// renders "Cancelled" with the partial output the job captured.
App.cancelJob = async function() {
    const job = this.activeJob;
    if (!job || job.cancelling) return;
    const btn = document.getElementById('cancelBtn');
    const status = document.getElementById('runStatus');
    job.cancelling = true;
    if (btn) btn.disabled = true;
    if (status) status.textContent = 'Cancelling...';
    try {
        await API.cancelJob(job.id);
        job.cancelled = true;
        job.stopped = true;
    } catch (e) {
        job.cancelling = false;
        if (e.status === 409) {
            // Finished on its own; polling will pick up the real result.
            Components.toast('Job already finished', 'info');
        } else {
            if (btn && this.activeJob === job) btn.disabled = false;
            Components.toast(e.status === 404 ? 'Job no longer exists' : `Cancel failed: ${e.message}`, 'error');
        }
    }
};

// Returns the finished job, or null when the loop was stopped (cancelled, or the user navigated away).
App.pollJob = async function(job, statusEl) {
    let polls = 0;
    let failures = 0;  // consecutive failed polls
    const maxPoll = 600;  // 10 min timeout

    while (polls < maxPoll) {
        await new Promise(r => setTimeout(r, 1000));
        if (job.stopped) return null;
        polls++;

        try {
            const data = await API.getJob(job.id);
            if (job.stopped) return null;
            failures = 0;

            if (data.status === 'running') {
                // Throttled so the aria-live status region is not announced every second.
                if (statusEl && polls % 5 === 1) statusEl.textContent = `Running... ${data.elapsed || polls}s`;
                continue;
            }

            // Completed, failed or cancelled
            return data;
        } catch (e) {
            if (job.stopped) return null;
            failures++;
            if (failures >= 5) {
                return { success: false, output: [{ stream: 'Error', message: `Lost connection to job: ${e.message}` }], durationMs: 0 };
            }
        }
    }
    return { success: false, output: [{ stream: 'Error', message: 'Job timed out (10 min)' }], durationMs: 0 };
};
