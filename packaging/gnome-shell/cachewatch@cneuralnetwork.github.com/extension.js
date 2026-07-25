import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const PROGRESS_WIDTH = 126;
const RESTART_DELAY_SECONDS = 3;

function clamp(value, minimum, maximum) {
    return Math.min(maximum, Math.max(minimum, value));
}

function compactNumber(value) {
    if (value === null || value === undefined)
        return '—';
    if (value >= 1_000_000)
        return `${(value / 1_000_000).toFixed(1)}m`;
    if (value >= 1_000)
        return `${Math.round(value / 1_000)}k`;
    return `${value}`;
}

function memory(value) {
    if (value === null || value === undefined)
        return '—';
    if (value >= 1_000_000_000)
        return `${(value / 1_000_000_000).toFixed(1)} GB`;
    return `${Math.round(value / 1_000_000)} MB`;
}

function duration(seconds) {
    const totalMinutes = Math.max(0, Math.floor(seconds / 60));
    if (totalMinutes < 60)
        return `${totalMinutes}m`;
    const hours = Math.floor(totalMinutes / 60);
    if (hours < 24)
        return `${hours}h ${totalMinutes % 60}m`;
    return `${Math.floor(hours / 24)}d ${hours % 24}h`;
}

function age(timestamp, now) {
    if (timestamp === null || timestamp === undefined)
        return 'no turns yet';
    return `${duration(now - timestamp)} ago`;
}

function resetLabel(timestamp, now) {
    if (timestamp === null || timestamp === undefined)
        return '';
    if (timestamp <= now)
        return 'reset pending';
    return `resets in ${duration(timestamp - now)}`;
}

function cacheLabel(session, now) {
    if (session.cacheState === 'warm' && session.cacheExpiresAt !== null)
        return `cache ${duration(session.cacheExpiresAt - now)}`;
    if (session.cacheState === 'cold')
        return 'cache cold';
    return null;
}

function sessionName(session) {
    if (session.name)
        return session.name;
    const parts = session.cwd.split('/').filter(Boolean);
    return parts.at(-1) ?? session.id.slice(0, 8);
}

function modelName(model) {
    if (!model)
        return 'model unknown';
    return model.split('[')[0].replace('claude-', '');
}

class ProgressBar extends St.Widget {
    static {
        GObject.registerClass(this);
    }

    constructor(percentage) {
        super({
            style_class: 'cachewatch-progress-track',
            layout_manager: new Clutter.BinLayout(),
        });

        const severity = percentage >= 90
            ? 'danger'
            : percentage >= 70 ? 'warning' : '';
        const fill = new St.Widget({
            style_class: `cachewatch-progress-fill ${severity}`.trim(),
            x_align: Clutter.ActorAlign.START,
            y_align: Clutter.ActorAlign.CENTER,
            width: Math.max(3, Math.round(PROGRESS_WIDTH * clamp(percentage, 0, 100) / 100)),
        });
        this.add_child(fill);
    }
}

class HeaderItem extends PopupMenu.PopupBaseMenuItem {
    static {
        GObject.registerClass(this);
    }

    constructor(summary) {
        super({
            reactive: false,
            can_focus: false,
            style_class: 'cachewatch-header',
        });

        const copy = new St.BoxLayout({vertical: true, x_expand: true});
        copy.add_child(new St.Label({
            text: 'Cachewatch',
            style_class: 'cachewatch-header-title',
        }));

        const states = [];
        if (summary.busy > 0)
            states.push(`${summary.busy} busy`);
        if (summary.waiting > 0)
            states.push(`${summary.waiting} waiting`);
        if (summary.idle > 0)
            states.push(`${summary.idle} idle`);
        const count = `${summary.total} session${summary.total === 1 ? '' : 's'}`;
        copy.add_child(new St.Label({
            text: [count, ...states].join('  ·  '),
            style_class: 'cachewatch-header-summary',
        }));
        this.add_child(copy);
        this.add_child(new St.Label({
            text: 'LIVE',
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'cachewatch-live-pill',
        }));
    }
}

class SectionLabel extends PopupMenu.PopupBaseMenuItem {
    static {
        GObject.registerClass(this);
    }

    constructor(text) {
        super({
            reactive: false,
            can_focus: false,
            style_class: 'cachewatch-section-label',
        });
        this.add_child(new St.Label({text}));
    }
}

class QuotaItem extends PopupMenu.PopupBaseMenuItem {
    static {
        GObject.registerClass(this);
    }

    constructor(quota, now) {
        super({
            reactive: false,
            can_focus: false,
            style_class: 'cachewatch-quota-item',
        });

        const copy = new St.BoxLayout({
            vertical: true,
            style_class: 'cachewatch-quota-copy',
        });
        copy.add_child(new St.Label({
            text: `${quota.provider === 'codex' ? 'Codex' : 'Claude'} · ${quota.window}`,
            style_class: 'cachewatch-quota-provider',
        }));
        copy.add_child(new St.Label({
            text: resetLabel(quota.resetsAt, now),
            style_class: 'cachewatch-muted',
        }));
        this.add_child(copy);
        this.add_child(new ProgressBar(quota.usedPercentage));
        this.add_child(new St.Label({
            text: `${Math.round(quota.usedPercentage)}%`,
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'cachewatch-percent',
        }));
    }
}

class SessionItem extends PopupMenu.PopupBaseMenuItem {
    static {
        GObject.registerClass(this);
    }

    constructor(session, now) {
        super({
            reactive: true,
            can_focus: true,
            style_class: 'cachewatch-session-item',
        });

        const content = new St.BoxLayout({vertical: true, x_expand: true});
        const top = new St.BoxLayout({x_expand: true});
        top.add_child(new St.Label({
            text: session.provider.toUpperCase(),
            style_class: `cachewatch-provider ${session.provider}`,
            y_align: Clutter.ActorAlign.CENTER,
        }));
        top.add_child(new St.Label({
            text: sessionName(session),
            style_class: 'cachewatch-session-name',
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        }));
        top.add_child(new St.Label({
            text: session.status.toUpperCase(),
            style_class: `cachewatch-status ${session.status}`,
            y_align: Clutter.ActorAlign.CENTER,
        }));
        content.add_child(top);

        const context = session.contextUsedPercentage === null
            || session.contextUsedPercentage === undefined
            ? `${compactNumber(session.contextTokens)} ctx`
            : `${Math.round(session.contextUsedPercentage)}% ctx · ${compactNumber(session.contextTokens)}`;
        const details = [
            modelName(session.model),
            context,
            cacheLabel(session, now),
            memory(session.memoryBytes),
            age(session.lastTurnAt, now),
        ].filter(Boolean);
        content.add_child(new St.Label({
            text: details.join('  ·  '),
            style_class: 'cachewatch-session-detail',
        }));
        this.add_child(content);
    }
}

class CachewatchIndicator extends PanelMenu.Button {
    static {
        GObject.registerClass(this);
    }

    constructor(extension) {
        super(0.5, 'Cachewatch');

        this._extension = extension;
        this._stopped = false;
        this._restartSourceId = 0;
        this._process = null;
        this._stream = null;
        this._cancellable = new Gio.Cancellable();

        const panel = new St.BoxLayout({style_class: 'cachewatch-panel'});
        panel.add_child(new St.Icon({
            gicon: Gio.icon_new_for_string(
                `${extension.path}/icons/cachewatch-symbolic.svg`
            ),
            style_class: 'system-status-icon',
        }));
        this._panelLabel = new St.Label({
            text: '…',
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'cachewatch-panel-label',
        });
        panel.add_child(this._panelLabel);
        this.add_child(panel);

        this._showStarting();
        this._startBackend();
    }

    shutdown() {
        this._stopped = true;
        this._cancellable.cancel();
        if (this._restartSourceId !== 0) {
            GLib.source_remove(this._restartSourceId);
            this._restartSourceId = 0;
        }
        if (this._process) {
            try {
                this._process.force_exit();
            } catch (error) {
                console.debug(`Cachewatch backend already stopped: ${error.message}`);
            }
        }
        this._process = null;
        this._stream = null;
    }

    _findBackend() {
        const fromPath = GLib.find_program_in_path('cachewatch');
        if (fromPath)
            return fromPath;

        const local = GLib.build_filenamev([
            GLib.get_home_dir(),
            '.local',
            'bin',
            'cachewatch',
        ]);
        return GLib.file_test(local, GLib.FileTest.IS_EXECUTABLE) ? local : null;
    }

    _startBackend() {
        const executable = this._findBackend();
        if (!executable) {
            this._showError(
                'Cachewatch CLI not found',
                'Run scripts/install-gnome-extension.sh from the Cachewatch repository.'
            );
            this._scheduleRestart();
            return;
        }

        try {
            this._process = Gio.Subprocess.new(
                [executable, 'stream', '--json'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
            this._stream = new Gio.DataInputStream({
                base_stream: this._process.get_stdout_pipe(),
                close_base_stream: true,
            });
            this._readNextLine();
            this._process.wait_async(this._cancellable, (process, result) => {
                try {
                    process.wait_finish(result);
                } catch (error) {
                    if (!this._stopped && !error.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                        console.error(`Cachewatch backend wait failed: ${error.message}`);
                }
                if (!this._stopped)
                    this._scheduleRestart();
            });
        } catch (error) {
            console.error(`Could not start Cachewatch: ${error.message}`);
            this._showError('Could not start Cachewatch', error.message);
            this._scheduleRestart();
        }
    }

    _readNextLine() {
        this._stream.read_line_async(
            GLib.PRIORITY_DEFAULT,
            this._cancellable,
            (stream, result) => {
                if (this._stopped)
                    return;
                try {
                    const [line] = stream.read_line_finish_utf8(result);
                    if (line === null)
                        return;
                    const snapshot = JSON.parse(line);
                    if (snapshot.schemaVersion !== 1)
                        throw new Error(`Unsupported snapshot schema ${snapshot.schemaVersion}`);
                    this._renderSnapshot(snapshot);
                    this._readNextLine();
                } catch (error) {
                    if (error.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                        return;
                    console.error(`Could not read Cachewatch snapshot: ${error.message}`);
                    this._showError('Live data unavailable', 'Cachewatch will reconnect automatically.');
                    this._process?.force_exit();
                }
            }
        );
    }

    _scheduleRestart() {
        if (this._stopped || this._restartSourceId !== 0)
            return;
        this._panelLabel.text = '!';
        this._restartSourceId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            RESTART_DELAY_SECONDS,
            () => {
                this._restartSourceId = 0;
                this._process = null;
                this._stream = null;
                this._showStarting();
                this._startBackend();
                return GLib.SOURCE_REMOVE;
            }
        );
    }

    _showStarting() {
        this._panelLabel.text = '…';
        this.menu.removeAll();
        this.menu.addMenuItem(new PopupMenu.PopupMenuItem(
            'Connecting to Cachewatch…',
            {reactive: false, can_focus: false}
        ));
    }

    _showError(title, detail) {
        this._panelLabel.text = '!';
        this.menu.removeAll();
        const item = new PopupMenu.PopupBaseMenuItem({
            reactive: false,
            can_focus: false,
            style_class: 'cachewatch-empty',
        });
        const copy = new St.BoxLayout({vertical: true});
        copy.add_child(new St.Label({
            text: title,
            style_class: 'cachewatch-error-title',
        }));
        copy.add_child(new St.Label({
            text: detail,
            style_class: 'cachewatch-error-copy',
        }));
        item.add_child(copy);
        this.menu.addMenuItem(item);
    }

    _renderSnapshot(snapshot) {
        const now = snapshot.generatedAt;
        this._panelLabel.text = `${snapshot.summary.total}`;
        this.menu.removeAll();
        this.menu.addMenuItem(new HeaderItem(snapshot.summary));

        if (snapshot.quotas.length > 0) {
            this.menu.addMenuItem(new SectionLabel('QUOTA'));
            for (const quota of snapshot.quotas)
                this.menu.addMenuItem(new QuotaItem(quota, now));
        }

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        if (snapshot.sessions.length === 0) {
            const item = new PopupMenu.PopupMenuItem(
                'No live Claude Code or Codex sessions.',
                {reactive: false, can_focus: false}
            );
            item.add_style_class_name('cachewatch-empty');
            this.menu.addMenuItem(item);
        } else {
            this.menu.addMenuItem(new SectionLabel('SESSIONS'));
            for (const session of snapshot.sessions)
                this.menu.addMenuItem(new SessionItem(session, now));
        }

        const footer = new PopupMenu.PopupMenuItem(
            'Updates live from local session data',
            {reactive: false, can_focus: false}
        );
        footer.add_style_class_name('cachewatch-footer');
        this.menu.addMenuItem(footer);
    }
}

export default class CachewatchExtension extends Extension {
    enable() {
        this._indicator = new CachewatchIndicator(this);
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    disable() {
        this._indicator?.shutdown();
        this._indicator?.destroy();
        this._indicator = null;
    }
}
