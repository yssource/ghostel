/// Ghostel — Emacs dynamic module entry point.
///
/// This is the top-level file compiled into ghostel-module.so/.dylib.
/// It exports emacs_module_init (the C entry point Emacs calls on load)
/// and registers all Elisp-callable functions.
const std = @import("std");
const emacs = @import("emacs.zig");
const GhostelTerm = @import("terminal.zig");
const gt = @import("ghostty-vt");
const input = @import("input.zig");
const kitty_graphics = @import("kitty_graphics.zig");
const sys = @import("sys.zig");
const pty = @import("pty.zig");

const c = emacs.c;

/// Module version — see src/version.zig.  Keep in sync with ghostel.el
/// and build.zig.zon.
const version = @import("version.zig").version;

// ---------------------------------------------------------------------------
// Module entry point
// ---------------------------------------------------------------------------

/// Emacs calls this when loading the dynamic module.
export fn emacs_module_init(runtime: *c.struct_emacs_runtime) callconv(.c) c_int {
    if (runtime.size < @sizeOf(c.struct_emacs_runtime)) {
        return 1; // ABI mismatch
    }

    const raw_env = runtime.get_environment.?(runtime);
    const env = emacs.Env.init(raw_env);

    emacs.initSymbols(env);

    // Register functions
    env.bindFunction("ghostel--new", 2, 5, &fnNew,
        \\Create a new ghostel terminal.
        \\
        \\(ghostel--new ROWS COLS &optional MAX-SCROLLBACK KITTY-STORAGE-LIMIT KITTY-MEDIUMS)
        \\
        \\KITTY-STORAGE-LIMIT is the kitty graphics image storage cap in bytes (default 320 MiB); 0 disables kitty graphics entirely.
        \\KITTY-MEDIUMS is a bitfield: bit 0 = file medium, bit 1 = temp-file medium, bit 2 = shared-memory medium (default 0 = direct only).
    );
    env.bindFunction("ghostel--write-input", 2, 2, &fnWriteInput,
        \\Write raw bytes to the terminal.
        \\
        \\(ghostel--write-input TERM DATA)
    );
    env.bindFunction("ghostel--set-size", 3, 5, &fnSetSize,
        \\Resize the terminal.
        \\
        \\(ghostel--set-size TERM ROWS COLS &optional CELL-W CELL-H)
    );
    env.bindFunction("ghostel--get-title", 1, 1, &fnGetTitle,
        \\Get the terminal title.
        \\
        \\(ghostel--get-title TERM)
    );
    env.bindFunction("ghostel--get-pwd", 1, 1, &fnGetPwd,
        \\Get the terminal's working directory from OSC 7.
        \\
        \\(ghostel--get-pwd TERM)
    );
    env.bindFunction("ghostel--redraw", 1, 2, &fnRedraw,
        \\Redraw the terminal into the current buffer.
        \\
        \\(ghostel--redraw TERM &optional FULL)
    );
    env.bindFunction("ghostel--encode-key", 3, 4, &fnEncodeKey,
        \\Encode a key event using the terminal's key encoder.
        \\
        \\(ghostel--encode-key TERM KEY MODS &optional UTF8)
    );
    env.bindFunction("ghostel--mouse-event", 6, 6, &fnMouseEvent,
        \\Send a mouse event to the terminal.
        \\
        \\(ghostel--mouse-event TERM ACTION BUTTON ROW COL MODS)
    );
    env.bindFunction("ghostel--focus-event", 2, 2, &fnFocusEvent,
        \\Send a focus event to the terminal.
        \\
        \\(ghostel--focus-event TERM GAINED)
    );
    env.bindFunction("ghostel--set-palette", 2, 2, &fnSetPalette,
        \\Set the ANSI color palette.
        \\
        \\(ghostel--set-palette TERM COLORS-STRING)
    );
    env.bindFunction("ghostel--set-default-colors", 3, 3, &fnSetDefaultColors,
        \\Set default foreground and background colors.
        \\
        \\(ghostel--set-default-colors TERM FG-HEX BG-HEX)
    );
    env.bindFunction("ghostel--set-bold-config", 2, 2, &fnSetBoldConfig,
        \\Configure bold text coloring.
        \\
        \\CONFIG can be nil (none), 'bright, or a hex color string.
        \\
        \\(ghostel--set-bold-config TERM CONFIG)
    );
    env.bindFunction("ghostel--mode-enabled", 2, 2, &fnModeEnabled,
        \\Return t if terminal DEC private MODE is enabled.
        \\
        \\(ghostel--mode-enabled TERM MODE)
    );
    env.bindFunction("ghostel--alt-screen-p", 1, 1, &fnAltScreen,
        \\Return t if terminal is on the alternate screen buffer.
        \\
        \\(ghostel--alt-screen-p TERM)
    );
    env.bindFunction("ghostel--copy-all-text", 1, 1, &fnCopyAllText,
        \\Return entire scrollback as plain text string.
        \\
        \\(ghostel--copy-all-text TERM)
    );
    env.bindFunction("ghostel--module-version", 0, 0, &fnModuleVersion,
        \\Return the native module version string.
        \\
        \\(ghostel--module-version)
    );
    env.bindFunction("ghostel--enable-vt-log", 0, 0, &fnEnableVtLog,
        \\Enable libghostty internal log routing to *ghostel-debug*.
        \\
        \\(ghostel--enable-vt-log)
    );
    env.bindFunction("ghostel--disable-vt-log", 0, 0, &fnDisableVtLog,
        \\Disable libghostty internal log routing.
        \\
        \\(ghostel--disable-vt-log)
    );
    env.bindFunction("ghostel--native-uri-at", 3, 3, &fnUriAt,
        \\Get URI at ROW-from-bottom and COL.
        \\
        \\(ghostel--native-uri-at TERM ROW COL)
    );
    env.bindFunction("ghostel--pty-password-input-p", 1, 1, &fnPtyPasswordInputP,
        \\Return t if the tty at PATH is in canonical mode with echo off.
        \\
        \\This mirrors libghostty's password-input heuristic.  Returns nil when the path can't be opened, `tcgetattr' fails, or the tty is in some other state.
        \\
        \\(ghostel--pty-password-input-p PATH)
    );

    // Install system callbacks (PNG decoder for kitty graphics, logging).
    sys.init();

    env.provide("ghostel-module");
    return 0;
}

// ---------------------------------------------------------------------------
// Plugin version — required by Emacs >= 27
// ---------------------------------------------------------------------------

export const plugin_is_GPL_compatible: c_int = 0;

// ---------------------------------------------------------------------------
// Exported Elisp functions
// ---------------------------------------------------------------------------

/// (ghostel--new ROWS COLS &optional MAX-SCROLLBACK KITTY-STORAGE-LIMIT)
fn fnNew(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    // Reject out-of-range row/col counts rather than wrapping/panicking.
    const rows = std.math.cast(u16, env.extractInteger(args[0])) orelse {
        env.signalError("rows out of range", .{});
        return env.nil();
    };
    const cols = std.math.cast(u16, env.extractInteger(args[1])) orelse {
        env.signalError("cols out of range", .{});
        return env.nil();
    };
    const max_scrollback: usize = if (nargs > 2 and env.isNotNil(args[2]))
        (std.math.cast(usize, env.extractInteger(args[2])) orelse {
            env.signalError("max-scrollback out of range", .{});
            return env.nil();
        })
    else
        5 * 1024 * 1024; // ~5 MB, roughly 5k rows on an 80-column terminal

    // Default 320 MiB; explicit 0 disables kitty graphics entirely
    // (skips the storage allocation in libghostty's screen state).
    const kitty_storage_limit: usize = if (nargs > 3 and env.isNotNil(args[3]))
        (std.math.cast(usize, env.extractInteger(args[3])) orelse {
            env.signalError("kitty-storage-limit out of range", .{});
            return env.nil();
        })
    else
        320 * 1024 * 1024;

    // Bit 0 = file medium, bit 1 = temp_file, bit 2 = shared_mem.
    // Default 0 — only the direct medium (base64 inline) is enabled.
    // The other mediums let a remote program instruct ghostel to read
    // arbitrary local files / SHM regions, so opt-in only.
    const kitty_mediums: u32 = if (nargs > 4 and env.isNotNil(args[4]))
        (std.math.cast(u32, env.extractInteger(args[4])) orelse 0)
    else
        0;

    var effects: gt.TerminalStream.Handler.Effects = .readonly;
    effects.write_pty = &writePtyCallback;
    effects.bell = &bellCallback;
    effects.device_attributes = &deviceAttributesCallback;
    effects.title_changed = &titleChangedCallback;
    effects.size = &sizeCallback;

    const term = GhostelTerm.init(cols, rows, max_scrollback, effects) catch {
        env.signalError("failed to create terminal", .{});
        return env.nil();
    };

    // Set default colors (light gray on black)
    term.setColorForeground(.{ .r = 204, .g = 204, .b = 204 });
    term.setColorBackground(.{ .r = 0, .g = 0, .b = 0 });

    // Enable kitty graphics protocol if storage limit > 0.
    if (kitty_storage_limit > 0) {
        term.enableKittyGraphics(
            kitty_storage_limit,
            (kitty_mediums & 0x1) != 0,
            (kitty_mediums & 0x2) != 0,
            (kitty_mediums & 0x4) != 0,
        ) catch |err|
            env.logError("enableKittyGraphics failed: %s", .{@errorName(err)});
    }

    return env.makeUserPtr(&GhostelTerm.emacsFinalize, term);
}

/// (ghostel--write-input TERM DATA)
fn fnWriteInput(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse {
        env.signalError("invalid terminal handle", .{});
        return env.nil();
    };

    // Extract string data — try stack buffer first, fall back to alloc
    var stack_buf: [65536]u8 = undefined;
    var heap_buf: ?[]const u8 = null;
    defer if (heap_buf) |hb| std.heap.c_allocator.free(hb);

    const data = env.extractString(args[1], &stack_buf) orelse blk: {
        heap_buf = env.extractStringAlloc(args[1], std.heap.c_allocator);
        break :blk heap_buf;
    };

    if (data == null) {
        return env.nil();
    }

    // Stash env for callbacks (and for the VT log callback)
    term.env = env;
    defer term.env = null;
    if (vt_log_active) {
        vt_log_env = env;
        defer vt_log_env = null;
    }

    const raw = data.?;

    // Respond to OSC 4/10/11 color queries BEFORE feeding libghostty.
    // libghostty will synchronously emit responses for other queries in
    // the same write (e.g. CSI 6n cursor-position report) via the
    // write_pty callback, and termenv-based programs read only the first
    // response chunk — so the color reply must be on the wire first or
    // the program discards our reply as noise.
    extractOscColorQueries(env, term, raw);

    // Normalize CRLF by streaming directly into libghostty's parser.
    // Emacs PTYs lack ONLCR, so bare \n arrives without \r — insert
    // one before each bare \n by feeding the preceding segment verbatim
    // and then "\r\n".  libghostty's VT state machine handles arbitrary
    // chunking (that's how the process filter already works), so no
    // scratch buffer, no allocation, no truncation fallback.
    //
    // `prev_was_cr` is seeded from `term.last_input_was_cr` so a CRLF
    // pair split across two writes — chunk A ending with \r, chunk B
    // starting with \n — is not mis-normalized into \r\r\n.  The final
    // value is persisted back for the next call. An empty input
    // round-trips the flag unchanged.
    var seg_start: usize = 0;
    var prev_was_cr: bool = term.last_input_was_cr;
    for (raw, 0..) |ch, i| {
        if (ch == '\n' and !prev_was_cr) {
            if (i > seg_start) term.vtWrite(raw[seg_start..i]);
            term.vtWrite("\r\n");
            seg_start = i + 1;
            prev_was_cr = false;
        } else {
            prev_was_cr = (ch == '\r');
        }
    }
    if (seg_start < raw.len) {
        term.vtWrite(raw[seg_start..]);
    }
    term.last_input_was_cr = prev_was_cr;

    // Scan for OSC sequences that libghostty-vt discards (7, 51, 52, 133).
    // One pass, dispatched by code in document order.
    dispatchPostWriteOscs(env, term, raw);

    return env.nil();
}

// ---------------------------------------------------------------------------
// OSC sequence helpers
// ---------------------------------------------------------------------------

/// An OSC sequence extracted by `OscIterator`.
const OscEntry = struct {
    /// Decimal OSC code (e.g. 4, 7, 10, 11, 51, 52, 133).
    code: u32,
    /// Payload bytes between the code's trailing `;` and the terminator.
    payload: []const u8,
    /// Terminator bytes (BEL or ESC \) — forwarded back on replies.
    terminator: []const u8,
};

/// Single-pass iterator over well-formed OSC sequences in a byte slice.
/// Advances past `ESC ]`, parses the decimal code up to `;`, locates the
/// BEL/ST terminator, and yields `(code, payload, terminator)`.
///
/// An OSC payload is bounded by a real terminator (BEL or ESC \) OR by
/// the next OSC introducer (ESC ]).  Stopping at a following introducer
/// handles malformed input where one OSC is missing its terminator
/// before the next begins — otherwise the partial OSC would cannibalize
/// the following OSC's bytes (including its terminator) as its own
/// payload, producing a garbage dispatch AND starving the next OSC.
/// On partial detection we advance past the current introducer and let
/// iteration continue, so well-formed OSCs later in the same buffer
/// still dispatch.
const OscIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *OscIterator) ?OscEntry {
        while (self.pos < self.data.len) {
            const intro = std.mem.indexOfPos(u8, self.data, self.pos, "\x1b]") orelse {
                self.pos = self.data.len;
                return null;
            };
            const code_start = intro + 2;

            // Decimal code up to the first `;`.
            var code_end = code_start;
            while (code_end < self.data.len and self.data[code_end] >= '0' and self.data[code_end] <= '9') {
                code_end += 1;
            }
            if (code_end == code_start or code_end >= self.data.len or self.data[code_end] != ';') {
                self.pos = code_start;
                continue;
            }
            const payload_start = code_end + 1;

            // Scan for a terminator (BEL or ESC \) or the next OSC
            // introducer (ESC ]), whichever comes first. An intervening
            // introducer means the current OSC is partial.
            var end = payload_start;
            var term_len: usize = 0;
            while (end < self.data.len) : (end += 1) {
                const ch = self.data[end];
                if (ch == 0x07) {
                    term_len = 1;
                    break;
                }
                if (ch == 0x1b and end + 1 < self.data.len) {
                    const next_ch = self.data[end + 1];
                    if (next_ch == '\\') {
                        term_len = 2;
                        break;
                    }
                    if (next_ch == ']') {
                        // Next introducer — current OSC is partial.
                        break;
                    }
                }
            }
            if (term_len == 0) {
                // Partial OSC: skip past the current introducer (which
                // we already parsed) and resume scanning. If `end` is
                // still `self.data.len` there were no more introducers,
                // and the next indexOfPos call will terminate iteration.
                self.pos = if (end > code_start) end else code_start;
                continue;
            }

            self.pos = end + term_len;
            const code = std.fmt.parseInt(u32, self.data[code_start..code_end], 10) catch continue;
            return .{
                .code = code,
                .payload = self.data[payload_start..end],
                .terminator = self.data[end .. end + term_len],
            };
        }
        return null;
    }
};

/// Dispatch OSC 7 / 51 / 52 / 133 from `data` in document order.
/// These are the post-vtWrite sequences that libghostty-vt discards,
/// so ghostel has to scan for them itself.  All four used to scan the
/// buffer independently; one unified pass is strictly less work for
/// bulk output and preserves source-order dispatch.  (OSC 4/10/11
/// color queries use the same iterator but run before vtWrite — see
/// `extractOscColorQueries`.)
///
/// Runs AFTER `vtWrite` so libghostty has already seen the bytes —
/// OSC 7 calls back into libghostty (`setPwd`) and the others call
/// Elisp.
fn dispatchPostWriteOscs(env: emacs.Env, term: *GhostelTerm, data: []const u8) void {
    var it = OscIterator{ .data = data };
    while (it.next()) |osc| {
        switch (osc.code) {
            // OSC 7: working directory as a file:// URL.
            7 => {
                if (osc.payload.len == 0) continue;
                term.terminal.setPwd(osc.payload) catch |err|
                    env.logError("setPwd failed: %s", .{@errorName(err)});
            },
            // OSC 51;E: whitelisted Elisp eval (ghostel extension).
            51 => {
                if (osc.payload.len < 2 or osc.payload[0] != 'E') continue;
                _ = env.f("ghostel--osc51-eval", .{osc.payload[1..]});
            },
            // OSC 52: clipboard set.  Queries ("?") are ignored.
            52 => {
                const semi = std.mem.indexOfScalar(u8, osc.payload, ';') orelse continue;
                const selection = osc.payload[0..semi];
                const b64 = osc.payload[semi + 1 ..];
                if (b64.len == 0) continue;
                if (b64.len == 1 and b64[0] == '?') continue;
                _ = env.f("ghostel--osc52-handle", .{ selection, b64 });
            },
            // OSC 133: semantic prompt markers (A/B/C/D/P).  P is
            // "explicit prompt start" — same as A for navigation but
            // without libghostty's fresh-line side effect, used by the
            // zsh `zle-line-init' fallback when PROMPT-wrap was lost.
            133 => {
                if (osc.payload.len == 0) continue;
                const marker_type = osc.payload[0];
                if (marker_type != 'A' and marker_type != 'B' and marker_type != 'C' and marker_type != 'D' and marker_type != 'P') continue;
                const has_param = osc.payload.len > 1 and osc.payload[1] == ';';
                const param_data = if (has_param) osc.payload[2..] else &[_]u8{};
                const type_str: [1]u8 = .{marker_type};
                const param_val = if (has_param and param_data.len > 0)
                    env.makeString(param_data)
                else
                    env.nil();
                _ = env.f("ghostel--osc133-marker", .{ &type_str, param_val });
            },
            // OSC 9: iTerm2 desktop notification, with ConEmu sub-codes
            // carved out (see `dispatchOsc9`).
            9 => dispatchOsc9(env, term, osc.payload),
            // OSC 777: rxvt "notify" extension — `notify;TITLE;BODY`.
            777 => dispatchOsc777(env, osc.payload),
            else => {},
        }
    }
}

/// Dispatch OSC 9.  The iTerm2 form is `9;<body>` with no title; ConEmu
/// overloads the same code with `9;<subcode>[;...]` for unrelated things
/// (progress, tab titles, env vars, etc.).  Ghostel implements two of the
/// sub-codes — `9;4` progress reports (routed to `ghostel--osc-progress`)
/// and `9;9` CWD reporting (routed through libghostty's `setPwd`, same as
/// OSC 7).  Other recognised ConEmu sub-codes are silently dropped so
/// stray control sequences don't pop spurious notifications.  Anything
/// that isn't a valid ConEmu sub-code falls through to
/// `ghostel--handle-notification` as an iTerm2 notification.  The
/// validation rules here mirror ghostty-vt's osc9.zig so ghostel's
/// drop/route/notify split stays consistent with upstream's parse.
fn dispatchOsc9(env: emacs.Env, term: *GhostelTerm, payload: []const u8) void {
    if (payload.len == 0) return;

    const first = payload[0];
    if (first >= '0' and first <= '9') {
        // Parse the leading digit run.
        var i: usize = 0;
        while (i < payload.len and payload[i] >= '0' and payload[i] <= '9') : (i += 1) {}
        const subcode_str = payload[0..i];
        const rest = payload[i..];
        const subcode = std.fmt.parseInt(u16, subcode_str, 10) catch {
            dispatchOsc9Notification(env, payload);
            return;
        };

        // OSC 9;4: progress report.  Valid forms start with `;<digit>`;
        // anything else falls through to the iTerm2 notification path.
        if (subcode == 4 and rest.len >= 2 and rest[0] == ';') {
            if (dispatchOsc9Progress(env, rest[1..])) return;
        }

        // OSC 9;9: ConEmu CWD reporting — same payload shape as OSC 7,
        // so we route it through `term.setPwd` (libghostty-vt discards
        // OSC 9, so this is the one place it gets picked up).
        if (subcode == 9 and rest.len >= 2 and rest[0] == ';') {
            const path = rest[1..];
            if (path.len > 0) {
                term.terminal.setPwd(path) catch |err|
                    env.logError("setPwd failed: %s", .{@errorName(err)});
            }
            return;
        }

        // Other recognised ConEmu sub-codes — silently dropped.  Each
        // check mirrors ghostty-vt's parser closely enough that payloads
        // it would reject fall through to the notification path below
        // (with two deliberate divergences — 9;5 and 9;12, see below).
        const is_conemu = switch (subcode) {
            1, 2, 3, 6, 7, 8, 11 => rest.len >= 1 and rest[0] == ';',
            // `9;5` (wait-input) and `9;12` (prompt start) take no
            // arguments.  ghostty-vt happens to consume trailing bytes
            // too, but matching that would swallow iTerm2 notifications
            // whose body starts with "5" or "12" (e.g. "5 minutes left")
            // — a realistic UX footgun — so we only treat these as
            // ConEmu when nothing follows the subcode.
            5, 12 => rest.len == 0,
            // `9;10` (bare) or `9;10;0..3[...]` → ConEmu xterm
            // emulation.  Anything else (`9;10;4`, `9;10;`, `9;10;abc`)
            // is invalid per ghostty-vt and must notify.  Matches
            // upstream's lax treatment of trailing bytes after a valid
            // first arg digit (e.g. `9;10;01`, `9;10;3x` → emulation).
            10 => rest.len == 0 or
                (rest.len >= 2 and rest[0] == ';' and
                    rest[1] >= '0' and rest[1] <= '3'),
            else => false,
        };
        if (is_conemu) return;
    }

    // Unrecognised `9;<digit>...` payloads fall through as iTerm2
    // notifications with the raw body (digit run included).  That's
    // intentional: the iTerm2 form has no sub-code namespace, so the
    // body is whatever follows the `9;`.
    dispatchOsc9Notification(env, payload);
}

fn dispatchOsc9Notification(env: emacs.Env, body: []const u8) void {
    _ = env.f("ghostel--handle-notification", .{ "", body });
}

/// Parse the payload that follows `9;4;` and dispatch to Elisp.  Returns
/// true if a progress event was emitted.
///
/// State semantics mirror ghostty-vt's parser at the protocol level:
///   - `set`  (1) defaults progress to 0 when unreported.
///   - `error` (2) / `pause` (4) accept an optional progress value.
///   - `remove` (0) / `indeterminate` (3) ignore any trailing progress.
///
/// Trailing-semicolon handling is slightly more forgiving than upstream:
/// `9;4;1;` and `9;4;1;50;` are treated the same as `9;4;1` and
/// `9;4;1;50`, whereas ghostty-vt's parseUnsigned returns null on the
/// trailing `;`.  Matters only for exotic emitters.
fn dispatchOsc9Progress(env: emacs.Env, data: []const u8) bool {
    if (data.len == 0) return false;
    const state_digit = data[0];
    const state_str: []const u8 = switch (state_digit) {
        '0' => "remove",
        '1' => "set",
        '2' => "error",
        '3' => "indeterminate",
        '4' => "pause",
        else => return false,
    };

    // Default progress: `set` starts at 0; all other states start nil.
    var progress_val = if (state_digit == '1') env.makeInteger(0) else env.nil();
    const accepts_progress = state_digit != '0' and state_digit != '3';

    if (accepts_progress and data.len >= 3 and data[1] == ';') {
        var tail = data[2..];
        // Trim trailing `;` so `9;4;0;` and similar don't fail to parse.
        while (tail.len > 0 and tail[tail.len - 1] == ';') tail.len -= 1;
        if (tail.len > 0) {
            // u64 is wide enough to absorb garbage like `99999999999`
            // without overflowing parseInt; the result is clamped to 100
            // regardless.
            if (std.fmt.parseInt(u64, tail, 10)) |n| {
                const clamped: i64 = @intCast(@min(n, 100));
                progress_val = env.makeInteger(clamped);
            } else |_| {}
        }
    }

    _ = env.f("ghostel--osc-progress", .{ state_str, progress_val });
    return true;
}

/// Dispatch OSC 777: `notify;TITLE;BODY`.  Any other extension is ignored
/// (rxvt defines `notify` as the only one we care about).
fn dispatchOsc777(env: emacs.Env, payload: []const u8) void {
    const first_semi = std.mem.indexOfScalar(u8, payload, ';') orelse return;
    if (!std.mem.eql(u8, payload[0..first_semi], "notify")) return;
    const after_ext = payload[first_semi + 1 ..];
    // Title and body are separated by the next `;`.  If no separator,
    // treat the whole remainder as body with empty title.
    const second_semi = std.mem.indexOfScalar(u8, after_ext, ';');
    const title = if (second_semi) |s| after_ext[0..s] else "";
    const body = if (second_semi) |s| after_ext[s + 1 ..] else after_ext;
    _ = env.f("ghostel--handle-notification", .{ title, body });
}

/// Send `OSC N;rgb:RRRR/GGGG/BBBB <term>` for a dynamic color (OSC 10/11).
fn sendDynamicColorReply(
    env: emacs.Env,
    osc_num: u8,
    color: gt.color.RGB,
    term_bytes: []const u8,
) void {
    var buf: [64]u8 = undefined;
    const written = std.fmt.bufPrint(
        &buf,
        "\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}",
        .{
            osc_num,
            color.r,
            color.r,
            color.g,
            color.g,
            color.b,
            color.b,
            term_bytes,
        },
    ) catch return;
    _ = env.f("ghostel--flush-output", .{written});
}

/// Send `OSC 4;INDEX;rgb:RRRR/GGGG/BBBB <term>` for a palette entry.
fn sendPaletteColorReply(
    env: emacs.Env,
    index: u16,
    color: gt.color.RGB,
    term_bytes: []const u8,
) void {
    var buf: [64]u8 = undefined;
    const written = std.fmt.bufPrint(
        &buf,
        "\x1b]4;{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}",
        .{
            index,
            color.r,
            color.r,
            color.g,
            color.g,
            color.b,
            color.b,
            term_bytes,
        },
    ) catch return;
    _ = env.f("ghostel--flush-output", .{written});
}

/// Scan data for OSC 4/10/11 color queries and emit responses in source
/// order.  libghostty applies OSC 4/10/11 **sets** internally but silently
/// drops the query form (`?` value), so ghostel scans the raw input and
/// replies itself.
///
/// Colors come from the terminal's currently effective state, which reflects
/// sets applied by earlier write-input calls — but NOT sets that appear
/// earlier in *this* input buffer, because this extractor runs before
/// `vtWrite` so the color reply is on the wire before any reply libghostty
/// generates itself (e.g. the CSI 6n cursor-position reply some programs
/// send in the same write).  Termenv-based readers consume the first chunk
/// off stdin, so ordering matters more than same-chunk freshness.
///
/// Only fully-terminated OSC sequences produce a reply: a query split
/// across two process-output chunks is ignored until a later call carries
/// the terminator.
fn extractOscColorQueries(env: emacs.Env, term: *GhostelTerm, data: []const u8) void {
    var it = OscIterator{ .data = data };
    while (it.next()) |osc| {
        switch (osc.code) {
            10 => {
                if (!std.mem.eql(u8, osc.payload, "?")) continue;
                const fg = term.terminal.colors.foreground.get();
                if (fg) |color| sendDynamicColorReply(env, 10, color, osc.terminator);
            },
            11 => {
                if (!std.mem.eql(u8, osc.payload, "?")) continue;
                const bg = term.terminal.colors.background.get();
                if (bg) |color| sendDynamicColorReply(env, 11, color, osc.terminator);
            },
            4 => {
                // Payload is a ';'-separated list of `index;value` pairs.
                // Reply only to pairs whose value is literally "?".
                var sub = std.mem.splitScalar(u8, osc.payload, ';');
                while (sub.next()) |index_tok| {
                    const value_tok = sub.next() orelse break;
                    if (!std.mem.eql(u8, value_tok, "?")) continue;
                    const idx = std.fmt.parseInt(u32, index_tok, 10) catch continue;
                    if (idx >= 256) continue;
                    const color = term.terminal.colors.palette.current[idx];
                    sendPaletteColorReply(env, @intCast(idx), color, osc.terminator);
                }
            },
            else => {},
        }
    }
}

/// (ghostel--set-size TERM ROWS COLS &optional CELL-W CELL-H)
fn fnSetSize(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse {
        env.signalError("invalid terminal handle", .{});
        return env.nil();
    };

    const rows = std.math.cast(u16, env.extractInteger(args[1])) orelse {
        env.signalError("rows out of range", .{});
        return env.nil();
    };
    const cols = std.math.cast(u16, env.extractInteger(args[2])) orelse {
        env.signalError("cols out of range", .{});
        return env.nil();
    };

    // Clamp cell dimensions to at least 1.  A zero (or negative,
    // pre-cast) value would propagate into the OPT_SIZE answer, and
    // some apps treat zero cell sizes as "kitty graphics not
    // supported" and fall back to half-block rendering.
    const cell_w: u32 = if (nargs > 3 and env.isNotNil(args[3])) blk: {
        const raw = env.extractInteger(args[3]);
        if (raw < 1) break :blk 1;
        break :blk std.math.cast(u32, raw) orelse 1;
    } else 1;

    const cell_h: u32 = if (nargs > 4 and env.isNotNil(args[4])) blk: {
        const raw = env.extractInteger(args[4]);
        if (raw < 1) break :blk 1;
        break :blk std.math.cast(u32, raw) orelse 1;
    } else 1;

    term.resize(cols, rows, cell_w, cell_h);
    return env.nil();
}

/// (ghostel--get-title TERM)
fn fnGetTitle(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    const title = term.terminal.getTitle();
    return if (title) |t| env.makeString(t) else env.nil();
}

/// (ghostel--pty-password-input-p PATH)
fn fnPtyPasswordInputP(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    var stack_buf: [1024]u8 = undefined;
    const path = env.extractString(args[0], &stack_buf) orelse return env.nil();
    return if (pty.isPasswordMode(path)) env.t() else env.nil();
}

/// (ghostel--get-pwd TERM)
fn fnGetPwd(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    const pwd = term.terminal.getPwd();
    return if (pwd) |p| env.makeString(p) else env.nil();
}

/// (ghostel--redraw TERM &optional FULL)
/// Reads the render state and updates the current Emacs buffer with styled text.
/// When FULL is non-nil, always perform a full redraw instead of incremental.
fn fnRedraw(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    const force_full = nargs > 1 and env.isNotNil(args[1]);
    if (vt_log_active) {
        vt_log_env = env;
        defer vt_log_env = null;
    }

    term.renderer.redraw(env, term, force_full) catch |err| {
        env.logStackTrace(@errorReturnTrace());
        env.signalError("Redraw failed: %s", .{@errorName(err)});
        return env.nil();
    };

    // `redraw' parks the libghostty viewport one row above the active
    // area for the next-redraw incremental change detection.  Kitty
    // placement queries report `viewport_row' relative to the current
    // viewport, so reading them with the parked offset shifts every
    // placement up by 1, anchoring the resulting overlay one row too
    // low and covering the prompt that sits just below the image.
    // Restore to the active area (SCROLL_BOTTOM) for the kitty calls,
    // then re-park afterwards.
    term.terminal.scrollViewport(.bottom);
    defer term.terminal.scrollViewport(.{ .delta = -1 });

    // Clear viewport-region kitty overlays after redraw so the cleared
    // region is computed against the post-promotion `scrollback_in_buffer`.
    // Running kitty-clear before redraw would use the pre-promotion viewport
    // boundary, wiping the overlay on the row that's about to be promoted
    // into scrollback — exactly the row we want to keep tagged.
    _ = env.f("ghostel--kitty-clear", .{});
    kitty_graphics.emitPlacements(env, term) catch |err| {
        env.logStackTrace(@errorReturnTrace());
        env.logError("emitPlacements failed: %s", .{@errorName(err)});
    };

    return env.nil();
}

/// (ghostel--encode-key TERM KEY MODS &optional UTF8)
/// Encode a key event and send it to the PTY.
/// KEY is a key name string (e.g. "a", "return", "up", "f1").
/// MODS is a modifier string (e.g. "ctrl", "shift,ctrl", "").
/// UTF8 is optional text generated by the key (e.g. "a" for the 'a' key).
fn fnEncodeKey(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    // Extract key name
    var key_buf: [64]u8 = undefined;
    const key_name = env.extractString(args[1], &key_buf) orelse return env.nil();

    // Extract modifiers
    var mod_buf: [64]u8 = undefined;
    const mod_str = env.extractString(args[2], &mod_buf) orelse "";

    // Extract optional UTF-8 text
    var utf8_buf: [32]u8 = undefined;
    const utf8: ?[]const u8 = if (nargs > 3 and env.isNotNil(args[3]))
        env.extractString(args[3], &utf8_buf)
    else
        null;

    const key = input.mapKey(key_name);
    const mods = input.parseMods(mod_str);

    const sent = input.encodeAndSend(env, term, key, mods, utf8) catch |err| {
        env.logStackTrace(@errorReturnTrace());
        env.signalError("encodeAndSend failed: %s", .{@errorName(err)});
        return env.nil();
    };
    return if (sent) env.t() else env.nil();
}

/// (ghostel--mouse-event TERM ACTION BUTTON ROW COL MODS)
/// ACTION: 0=press, 1=release, 2=motion
/// BUTTON: 0=none, 1=left, 2=right, 3=middle
/// ROW, COL: 0-based cell coordinates
/// MODS: modifier bitmask
fn fnMouseEvent(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    const action = env.extractInteger(args[1]);
    const button = env.extractInteger(args[2]);
    const row = env.extractInteger(args[3]);
    const col = env.extractInteger(args[4]);
    const mods = env.extractInteger(args[5]);

    const sent = input.encodeAndSendMouse(env, term, action, button, row, col, mods) catch |err| {
        env.logStackTrace(@errorReturnTrace());
        env.signalError("encodeAndSendMouse failed: %s", .{@errorName(err)});
        return env.nil();
    };
    return if (sent) env.t() else env.nil();
}

/// (ghostel--focus-event TERM GAINED)
/// Encode a focus gained/lost event and send to the PTY.
/// Only sends if the terminal has enabled focus reporting (DEC mode 1004).
fn fnFocusEvent(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    // Only send focus events if the terminal has enabled mode 1004
    if (!term.terminal.modes.get(gt.modes.Mode.focus_event)) {
        return env.nil();
    }

    const gained = env.isNotNil(args[1]);
    const event = if (gained) gt.input.FocusEvent.gained else gt.input.FocusEvent.lost;

    var buf: [8]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    gt.input.encodeFocus(&writer, event) catch return env.nil();
    const encoded = writer.buffered();
    if (encoded.len == 0) return env.nil();

    // Stash env for the flush callback
    term.env = env;
    defer term.env = null;

    _ = env.f("ghostel--flush-output", .{encoded});
    return env.t();
}

/// (ghostel--mode-enabled TERM MODE)
/// Return t if terminal DEC private MODE is enabled, nil otherwise.
fn fnModeEnabled(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    const raw_int = env.extractInteger(args[1]);
    const mode_int = std.math.cast(u16, raw_int) orelse {
        env.signalError("invalid mode value: %d", .{raw_int});
        return env.nil();
    };
    const mode = std.meta.intToEnum(gt.modes.Mode, mode_int) catch {
        env.signalError("invalid mode value: %d", .{raw_int});
        return env.nil();
    };
    return if (term.terminal.modes.get(mode)) env.t() else env.nil();
}

/// (ghostel--alt-screen-p TERM)
/// Return t if the terminal is on the alternate screen buffer.
fn fnAltScreen(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    return if (term.terminal.screens.active_key == .alternate) env.t() else env.nil();
}

/// (ghostel--set-palette TERM COLORS-STRING)
/// Set the 16 ANSI colors from a concatenated hex string like "#000000#aa0000...".
/// The remaining 240 palette entries are taken from the terminal's current palette.
fn fnSetPalette(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse {
        env.signalError("invalid terminal handle", .{});
        return env.nil();
    };

    var str_buf: [2048]u8 = undefined;
    const colors_str = env.extractString(args[1], &str_buf) orelse {
        env.signalError("invalid palette string", .{});
        return env.nil();
    };

    // Get current palette as base (keeps entries 16-255)
    var palette = term.terminal.colors.palette.current;

    // Parse "#RRGGBB" entries — 7 chars each
    var idx: usize = 0;
    var pos: usize = 0;
    while (idx < 16 and pos + 7 <= colors_str.len) {
        if (colors_str[pos] != '#') {
            pos += 1;
            continue;
        }
        const r = parseHexByte(colors_str[pos + 1], colors_str[pos + 2]) orelse {
            pos += 7;
            idx += 1;
            continue;
        };
        const g = parseHexByte(colors_str[pos + 3], colors_str[pos + 4]) orelse {
            pos += 7;
            idx += 1;
            continue;
        };
        const b = parseHexByte(colors_str[pos + 5], colors_str[pos + 6]) orelse {
            pos += 7;
            idx += 1;
            continue;
        };
        palette[idx] = .{ .r = r, .g = g, .b = b };
        idx += 1;
        pos += 7;
    }

    term.setColorPalette(palette);
    return env.t();
}

fn parseHexByte(hi: u8, lo: u8) ?u8 {
    const h = hexDigit(hi) orelse return null;
    const l = hexDigit(lo) orelse return null;
    return (h << 4) | l;
}

fn hexDigit(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

/// Parse a "#RRGGBB" hex color string into a ColorRgb.
fn parseHexColor(s: []const u8) ?gt.color.RGB {
    if (s.len < 7 or s[0] != '#') return null;
    const r = parseHexByte(s[1], s[2]) orelse return null;
    const g = parseHexByte(s[3], s[4]) orelse return null;
    const b = parseHexByte(s[5], s[6]) orelse return null;
    return .{ .r = r, .g = g, .b = b };
}

/// (ghostel--set-default-colors TERM FG-HEX BG-HEX)
/// Set the terminal's default foreground and background colors from "#RRGGBB" strings.
fn fnSetDefaultColors(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse {
        env.signalError("invalid terminal handle", .{});
        return env.nil();
    };

    var fg_buf: [16]u8 = undefined;
    var bg_buf: [16]u8 = undefined;
    const fg_str = env.extractString(args[1], &fg_buf) orelse {
        env.signalError("invalid foreground color", .{});
        return env.nil();
    };
    const bg_str = env.extractString(args[2], &bg_buf) orelse {
        env.signalError("invalid background color", .{});
        return env.nil();
    };

    const fg = parseHexColor(fg_str) orelse {
        env.signalError("cannot parse foreground color", .{});
        return env.nil();
    };
    const bg = parseHexColor(bg_str) orelse {
        env.signalError("cannot parse background color", .{});
        return env.nil();
    };

    term.setColorForeground(fg);
    term.setColorBackground(bg);
    return env.t();
}

/// (ghostel--set-bold-config TERM CONFIG)
///
/// CONFIG can be nil (none), 'bright, or a hex color string.
fn fnSetBoldConfig(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    const val = args[1];

    if (env.isNil(val)) {
        term.renderer.bold_config = null;
    } else if (env.eq(val, emacs.sym.bright)) {
        term.renderer.bold_config = .bright;
    } else {
        var hex_buf: [16]u8 = undefined;
        const hex = env.extractString(val, &hex_buf) orelse {
            env.signalError("invalid bold config value", .{});
            return env.nil();
        };

        if (parseHexColor(hex)) |color| {
            term.renderer.bold_config = .{ .color = color };
        } else {
            env.signalError("invalid bold color: %s", .{hex});
            return env.nil();
        }
    }

    return env.t();
}

/// (ghostel--copy-all-text TERM)
/// Return the entire scrollback as a plain text string using the formatter API.
fn fnCopyAllText(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    const options = gt.formatter.Options{
        .emit = .plain,
        .unwrap = true,
        .trim = true,
    };

    var formatter = gt.formatter.TerminalFormatter.init(&term.terminal, options);
    var writer = std.io.Writer.Allocating.init(std.heap.c_allocator);
    defer writer.deinit();
    formatter.format(&writer.writer) catch {
        env.signalError("formatter failed", .{});
        return env.nil();
    };
    const written = writer.written();

    if (written.len == 0) return env.nil();
    return env.makeString(written);
}

/// (ghostel--module-version)
fn fnModuleVersion(raw_env: ?*c.emacs_env, _: isize, _: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    return env.makeString(version);
}

// ---------------------------------------------------------------------------
// Ghostty callbacks — invoked synchronously during vtWrite
// ---------------------------------------------------------------------------

/// Called when the terminal needs to write response data back to the PTY.
fn writePtyCallback(handler: *gt.TerminalStream.Handler, data: [:0]const u8) void {
    const term: *GhostelTerm = @fieldParentPtr("terminal", handler.terminal);
    const env = term.env orelse return;

    if (data.len == 0) return;
    _ = env.f("ghostel--flush-output", .{data});
}

/// Called when the terminal receives BEL.
fn bellCallback(handler: *gt.TerminalStream.Handler) void {
    const term: *GhostelTerm = @fieldParentPtr("terminal", handler.terminal);
    const env = term.env orelse return;

    _ = env.f("ding", .{});
}

const DeviceAttributesFn = @typeInfo(
    @typeInfo(
        @FieldType(gt.TerminalStream.Handler.Effects, "device_attributes"),
    ).optional.child,
).pointer.child;
const DeviceAttributes = @typeInfo(DeviceAttributesFn).@"fn".return_type.?;

/// Called when the terminal receives a device attributes query (DA1/DA2/DA3).
/// Reports as a VT220-compatible terminal with ANSI color support.
fn deviceAttributesCallback(_: *gt.TerminalStream.Handler) DeviceAttributes {
    return .{
        .primary = .{
            .conformance_level = .vt220,
            .features = &.{.ansi_color},
        },
        .secondary = .{
            .device_type = .vt220,
            .firmware_version = 1,
            .rom_cartridge = 0,
        },
        .tertiary = .{
            .unit_id = 0,
        },
    };
}

/// Called for XTWINOPS size queries (CSI 14/16/18 t).  libghostty
/// invokes this to learn the terminal's row/column count and cell
/// pixel dimensions, then encodes the appropriate response itself
/// and writes it via the write_pty callback.  Image-rendering tools
/// like timg use these queries to detect kitty graphics support and
/// size images correctly — without a response they fall back to
/// half-block rendering.
fn sizeCallback(handler: *gt.TerminalStream.Handler) ?gt.size_report.Size {
    const term: *GhostelTerm = @fieldParentPtr("terminal", handler.terminal);
    return .{
        .rows = term.terminal.rows,
        .columns = term.terminal.cols,
        .cell_width = term.terminal.width_px / term.terminal.cols,
        .cell_height = term.terminal.height_px / term.terminal.rows,
    };
}

/// Called when the terminal title changes.
fn titleChangedCallback(handler: *gt.TerminalStream.Handler) void {
    const term: *GhostelTerm = @fieldParentPtr("terminal", handler.terminal);
    const env = term.env orelse return;

    const title = term.terminal.getTitle();
    if (title) |t| {
        _ = env.f("ghostel--set-title", .{t});
    }
}

// ---------------------------------------------------------------------------
// zig log callback
// ---------------------------------------------------------------------------

pub const std_options: std.Options = .{ .logFn = logFn };

/// Global Emacs env stashed during any Elisp→Zig call where logging is
/// active.  Only valid on the main thread while a Zig function is
/// executing; set to null at all other times.
///
/// Thread safety: the GhosttySysLogFn contract requires thread safety,
/// but ghostel only drives libghostty from Emacs's main thread, so the
/// callback always fires on the same thread that stashed the env.  If
/// libghostty ever uses background threads, this would need a mutex or
/// a lock-free message queue.
var vt_log_env: ?emacs.Env = null;

/// Log callback matching GhosttySysLogFn.  Formats the message and
/// forwards it to `ghostel--debug-log-vt' in Elisp.
fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!vt_log_active) return;
    const env = vt_log_env orelse return;
    const level_str: []const u8 = switch (message_level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
    const scope_slice = @tagName(scope);
    var buf: [4096]u8 = undefined;
    const msg_slice = std.fmt.bufPrint(&buf, format, args) catch return;

    _ = env.f("ghostel--debug-log-vt", .{ level_str, scope_slice, msg_slice });

    // If the Elisp call signaled an error (e.g. ghostel--debug-log-vt is
    // void-function because ghostel-debug.el isn't loaded), clear it so it
    // doesn't leak into the calling context and disable logging to prevent
    // repeated errors.
    if (env.nonLocalExitCheck() != c.emacs_funcall_exit_return) {
        env.nonLocalExitClear();
        vt_log_active = false;
    }
}

/// Whether the VT log callback is installed.
var vt_log_active: bool = false;

/// (ghostel--enable-vt-log)
fn fnEnableVtLog(raw_env: ?*c.emacs_env, _: isize, _: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    vt_log_active = true;
    return env.t();
}

/// (ghostel--disable-vt-log)
fn fnDisableVtLog(raw_env: ?*c.emacs_env, _: isize, _: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    vt_log_active = false;
    return env.t();
}

fn fnUriAt(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    const row_from_bottom = env.extractInteger(args[1]);
    const col = env.extractInteger(args[2]);
    const total_rows = term.terminal.screens.active.pages.total_rows;

    if (col < 0 or col >= term.renderer.size.cols) return env.nil();
    // The Emacs buffer always carries a trailing newline, so the line
    // immediately after the last content row produces row_from_bottom == 0.
    if (row_from_bottom <= 0 or row_from_bottom > total_rows) return env.nil();
    const row = total_rows - @as(usize, @intCast(row_from_bottom));

    const point = gt.Point{ .screen = .{
        .x = @intCast(col),
        .y = @intCast(row),
    } };
    const pin = term.terminal.screens.active.pages.pin(point) orelse return env.nil();
    const cell = pin.rowAndCell().cell;
    if (!cell.hyperlink) {
        return env.nil();
    }

    const link_id = pin.node.data.lookupHyperlink(cell) orelse return env.nil();
    const entry = pin.node.data.hyperlink_set.get(pin.node.data.memory, link_id);
    const uri = entry.uri.slice(pin.node.data.memory);

    return env.makeString(uri);
}
