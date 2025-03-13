const py = @import("py");
const c = py.c;
const Object = py.Object;
const Module = py.Module;
const Tuple = py.Tuple;
const Dict = py.Dict;
const std = @import("std");

const member = @import("member.zig");
const atom_meta = @import("atom_meta.zig");
const atom = @import("atom.zig");
const observation = @import("observation.zig");
const observer_pool = @import("observer_pool.zig");
const modes = @import("modes.zig");
pub const package_name = "zatom";

pub const DebugLevel = struct {
    creates: bool = false,
    clears: bool = false,
    traverse: bool = false,
    clones: bool = false,
    defaults: bool = false,
    reads: bool = false,
    writes: bool = false,
    deletes: bool = false,
    gets: bool = false,
    sets: bool = false,
    decrefs: bool = false,
    name_filter: ?[:0]const u8 = null,

    pub fn matches(self: DebugLevel, name: ?*py.Str) bool {
        if (self.name_filter) |f| {
            if (name) |n| {
                return std.mem.eql(u8, n.data(), f);
            }
        }
        return true;
    }
};
pub const debug_level = DebugLevel{
    //.defaults=true, .reads=true, .writes=true, .deletes=true,
    //.gets=true, .sets=true,
    //.traverse=true,
    //.decrefs = true,
    //.name_filter="icon_size",
};
pub const debug_decrefs = debug_level.decrefs;

fn modexec(mod: *py.Module) !c_int {
    try member.initModule(mod);
    errdefer member.deinitModule(mod);
    try atom_meta.initModule(mod);
    errdefer atom_meta.deinitModule(mod);
    try atom.initModule(mod);
    errdefer atom.deinitModule(mod);
    try observation.initModule(mod);
    errdefer observation.deinitModule(mod);
    try observer_pool.initModule(mod);
    errdefer observer_pool.deinitModule(mod);
    try modes.initModule(mod);
    errdefer modes.deinitModule(mod);

    const builtins = try py.importModule("builtins");
    defer builtins.decref();
    try mod.addObject("ChangeDict", try builtins.getAttrString("dict"));

    return 0;
}

pub export fn atom_modexec(mod: *py.Module) c_int {
    return modexec(mod) catch |err| switch (err) {
        error.PyError => -1, // Python error
    };
}

pub fn add_member(_: *Module, args: [*]*Object, n: isize) ?*Object {
    if (n != 3 or !atom_meta.AtomMeta.check(args[0])) {
        return py.typeErrorObject(null, "Expected AtomMeta class", .{});
    }
    return atom_meta.AtomMeta.add_member(@ptrCast(args[0]), args[1..3], 2);
}

pub fn observe(_: *Module, args: *Tuple, kwargs: ?*Dict) ?*Object {
    return observation.ObserveHandler.TypeObject.?.call(args, kwargs) catch return null;
}

var module_methods = [_]py.MethodDef{
    .{ .ml_name = "add_member", .ml_meth = @constCast(@ptrCast(&add_member)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Add an atom member to a class" },
    .{ .ml_name = "observe", .ml_meth = @constCast(@ptrCast(&observe)), .ml_flags = py.c.METH_VARARGS | py.c.METH_KEYWORDS, .ml_doc = "Add a static observer on a method" },
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
