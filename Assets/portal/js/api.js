/* ═══════════════════════════════════════════════════════════
    Nexus — API Client
   ═══════════════════════════════════════════════════════════ */

const API = {
    baseUrl: window.location.origin,

    async _fetch(path, options = {}) {
        try {
            const res = await fetch(`${this.baseUrl}${path}`, {
                headers: { 'Content-Type': 'application/json' },
                ...options
            });
            if (!res.ok) {
                const err = await res.json().catch(() => ({ message: res.statusText }));
                const error = new Error(err.message || `HTTP ${res.status}`);
                error.status = res.status;
                throw error;
            }
            return await res.json();
        } catch (e) {
            console.error(`API error [${path}]:`, e);
            throw e;
        }
    },

    // ── Modules ──
    async getModules() {
        return this._fetch('/api/modules');
    },

    async getModuleCommands(moduleName) {
        return this._fetch(`/api/modules/${encodeURIComponent(moduleName)}/commands`);
    },

    async getModuleConnection(moduleName) {
        return this._fetch(`/api/modules/${encodeURIComponent(moduleName)}/connection`);
    },

    async disconnectModule(moduleName) {
        return this._fetch(`/api/modules/${encodeURIComponent(moduleName)}/connection`, { method: 'DELETE' });
    },

    // ── Commands ──
    async searchCommands(query) {
        const q = query ? `?search=${encodeURIComponent(query)}` : '';
        return this._fetch(`/api/commands${q}`);
    },

    async getCommandParams(moduleName, commandName) {
        return this._fetch(`/api/commands/${encodeURIComponent(moduleName)}/${encodeURIComponent(commandName)}/params`);
    },

    // ── Execute ──
    async executeCommand(moduleName, commandName, parameters = {}) {
        return this._fetch('/api/execute', {
            method: 'POST',
            body: JSON.stringify({
                module: moduleName,
                command: commandName,
                parameters: parameters
            })
        });
    },

    // ── Health ──
    async getHealth() {
        return this._fetch('/api/health');
    },

    // ── Registry ──
    async scanRegistry() {
        return this._fetch('/api/registry/scan', { method: 'POST' });
    },

    // ── Settings ──
    async getSettings() {
        return this._fetch('/api/settings');
    },

    // ── Favourites ──
    async getFavourites() {
        return this._fetch('/api/favourites');
    },

    async addFavourite(moduleName, commandName) {
        return this._fetch('/api/favourites', {
            method: 'POST',
            body: JSON.stringify({ module: moduleName, command: commandName })
        });
    },

    async removeFavourite(moduleName, commandName) {
        return this._fetch('/api/favourites', {
            method: 'DELETE',
            body: JSON.stringify({ module: moduleName, command: commandName })
        });
    },

    // ── Recent ──
    async getRecent() {
        return this._fetch('/api/recent');
    },

    async clearRecent() {
        return this._fetch('/api/recent', { method: 'DELETE' });
    },

    // ── Shutdown ──
    async shutdown() {
        return this._fetch('/api/shutdown', { method: 'POST' });
    }
};
