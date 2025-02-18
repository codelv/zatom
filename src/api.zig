pub const py = @import("deps/py.zig/py.zig");
const c = py.c;
const Object = py.Object;
const Module = py.Module;
const Tuple = py.Tuple;
const std = @import("std");

const member = @import("member.zig");
const atom_meta = @import("atom_meta.zig");
const atom = @import("atom.zig");
pub const package_name = "zatom";

/////////////////////////////////////////////////

fn modexec(mod: *py.Module) !c_int {
    try member.initModule(mod);
    errdefer member.deinitModule(mod);
    try atom_meta.initModule(mod);
    errdefer atom_meta.deinitModule(mod);
    try atom.initModule(mod);
    errdefer atom.deinitModule(mod);
    return 0;
}

pub export fn atom_modexec(mod: *py.Module) c_int {
    return modexec(mod) catch |err| switch (err) {
        error.PyError => -1, // Python error
    };
}

var module_methods = [_]py.MethodDef{
    .{}, // sentinel
};

var module_slots = [_]py.SlotDef{
    .{ .slot = c.Py_mod_exec, .value = @constCast(@ptrCast(&atom_modexec)) },
    .{}, // sentinel
};

pub var moduledef = py.ModuleDef.new(.{
    .m_name = package_name ++ ".atom",
    .m_doc = "atom module",
    .m_methods = &module_methods,
    .m_slots = &module_slots,
});

pub export fn PyInit_api(_: *anyopaque) [*c]Object {
    return moduledef.init();
}
