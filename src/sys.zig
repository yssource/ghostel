/// System interface for libghostty — PNG decoder and logging.
const std = @import("std");
const gt = @import("ghostty-vt");
const png = @import("png.zig");

/// Install system callbacks.  Call once at module init before any
/// terminal is created.
pub fn init() void {
    gt.sys.decode_png = &png.decode;
}
