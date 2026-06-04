/* ═══════════════════════════════════════════════════════════
    Nexus — Command Info UI Extensions
   Adds categorized command views, quick-start panel, descriptions
   ═══════════════════════════════════════════════════════════ */

const CommandsUI = {

    // ── Quick Start Panel ──
    // Shows connection commands + primary actions at the top of module detail
    quickStartPanel(quickStart, moduleName) {
        const conn = quickStart.connection || [];
        const primary = quickStart.primary || [];

        if (conn.length === 0 && primary.length === 0) return '';

        let html = '<div class="quickstart-panel"><h3>⚡ Quick Start</h3><div class="quickstart-grid">';

        if (conn.length > 0) {
            html += '<div class="quickstart-section">';
            html += '<h4>🔌 Connect First</h4>';
            html += '<div class="quickstart-commands">';
            conn.forEach(cmd => {
                html += `<button class="quickstart-cmd connection" onclick="App.navigate('#/commands/${encodeURIComponent(moduleName)}/${encodeURIComponent(cmd)}')" title="Connection command">
                    <span class="quickstart-verb">Connect</span>
                    <span class="quickstart-name">${Components.esc(cmd)}</span>
                </button>`;
            });
            html += '</div></div>';
        }

        if (primary.length > 0) {
            html += '<div class="quickstart-section">';
            html += '<h4>▶️ Then Run</h4>';
            html += '<div class="quickstart-commands">';
            primary.forEach(cmd => {
                const verb = cmd.match(/^([A-Za-z]+)-/);
                const verbLabel = verb ? verb[1] : 'Run';
                html += `<button class="quickstart-cmd primary" onclick="App.navigate('#/commands/${encodeURIComponent(moduleName)}/${encodeURIComponent(cmd)}')" title="Primary action">
                    <span class="quickstart-verb">${Components.esc(verbLabel)}</span>
                    <span class="quickstart-name">${Components.esc(cmd)}</span>
                </button>`;
            });
            html += '</div></div>';
        }

        html += '</div></div>';
        return html;
    },

    // ── Categorized Command Sections ──
    // Renders commands grouped by verb category with collapsible sections
    categorizedCommands(categories, moduleName, descriptions) {
        if (!categories || categories.length === 0) return '';

        let html = '';
        categories.forEach(cat => {
            const isCollapsed = cat.count > 20 ? 'collapsed' : '';
            const cmdRows = cat.commands.map(cmd => {
                const desc = (cmd.description || (descriptions && descriptions[cmd.name])) || '';
                const descHtml = desc ? `<span class="cmd-desc">${Components.esc(desc)}</span>` : '';
                return `<div class="cmd-row" onclick="App.navigate('#/commands/${encodeURIComponent(moduleName)}/${encodeURIComponent(cmd.name)}')">
                    <span class="cmd-name-cat">${Components.esc(cmd.name)}</span>
                    ${descHtml}
                </div>`;
            }).join('');

            html += `
            <div class="cmd-category ${isCollapsed}">
                <div class="cmd-category-header" onclick="this.parentElement.classList.toggle('collapsed')">
                    <span class="cmd-category-icon">${cat.icon || '📦'}</span>
                    <span class="cmd-category-label">${Components.esc(cat.label)}</span>
                    <span class="cmd-category-count">${cat.count}</span>
                    <span class="cmd-category-chevron">▾</span>
                </div>
                <div class="cmd-category-desc">${Components.esc(cat.description || '')}</div>
                <div class="cmd-category-body">${cmdRows}</div>
            </div>`;
        });

        return html;
    },

    // ── Load Descriptions Button ──
    loadDescriptionsButton(moduleName) {
        return `<button class="btn btn-sm" id="loadDescBtn" onclick="CommandsUI.fetchDescriptions('${Components.esc(moduleName)}')">
            📝 Load Descriptions
        </button>`;
    },

    async fetchDescriptions(moduleName) {
        const btn = document.getElementById('loadDescBtn');
        if (btn) { btn.disabled = true; btn.textContent = '⏳ Loading...'; }

        try {
            const data = await API.getModuleCommands(moduleName + '?describe=true');
            // Re-render the module detail with descriptions
            Components.toast(`Loaded ${Object.keys(data.commands.filter(c => c.description)).length} descriptions`, 'success');
            // Trigger a re-render
            App.renderModuleDetail(document.getElementById('content'), moduleName, data);
        } catch(e) {
            Components.toast(`Failed: ${e.message}`, 'error');
            if (btn) { btn.disabled = false; btn.textContent = '📝 Load Descriptions'; }
        }
    }
};

// Extend the API client to support query params on getModuleCommands
const _origGetModuleCommands = API.getModuleCommands.bind(API);
API.getModuleCommands = async function(moduleNameOrUrl) {
    // Support passing "ModuleName?describe=true"
    if (moduleNameOrUrl.includes('?')) {
        const [name, query] = moduleNameOrUrl.split('?');
        return this._fetch(`/api/modules/${encodeURIComponent(name)}/commands?${query}`);
    }
    return _origGetModuleCommands(moduleNameOrUrl);
};
