const py = @import("py.zig");
const c = py.c;
const Object = py.Object;
const Module = py.Module;
const Tuple = py.Tuple;
const std = @import("std");

const members = @import("members.zig");
const atom_meta = @import("atom_meta.zig");
pub const package_name = "zatom";

/////////////////////////////////////////////////

pub export fn sum(self: *Module, args: *Tuple) ?*Object {
    var a: c_long = undefined;
    var b: c_long = undefined;
    _ = self;
    args.parse("ll", .{&a, &b}) catch return null;
    return @ptrCast(py.Int.fromInt(a + b));
}


fn modexec(mod: *py.Module) !c_int {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("modexec\n", .{});
    try members.initModule(mod);
    errdefer members.deinitModule(mod);
    try atom_meta.initModule(mod);
    errdefer atom_meta.deinitModule(mod);
    return 0;
}

pub export fn atom_modexec(mod: *py.Module) c_int {
    return modexec(mod) catch |err| switch (err) {
        error.PyError => -1, // Python error
        else => blk: {
            // Set error if a sign error ocurred
            _ = py.systemError("atom init failed");
            break :blk -1;
        },
    };
}

var methods = [_]py.MethodDef{
    .{
        .ml_name = "sum",
        .ml_meth = @ptrCast(&sum),
        .ml_flags = 1,
        .ml_doc = null,
    },
    .{} // sentinel
};

var slots = [_]py.SlotDef{
    .{.slot = c.Py_mod_exec, .value = @constCast(@ptrCast(&atom_modexec))},
    .{} // sentinel
};

pub var moduledef = py.ModuleDef.new(.{
    .m_name = package_name ++ ".atom",
    .m_doc = "atom module",
    .m_methods = &methods,
    .m_slots = &slots,
});

pub export fn PyInit_api( _:*anyopaque ) [*c]Object {
    return moduledef.init();
}
