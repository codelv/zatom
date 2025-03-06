const py = @import("../api.zig").py;
const std = @import("std");
const Object = py.Object;
const Tuple = py.Tuple;
const Dict = py.Dict;
const Str = py.Str;
const Atom = @import("../atom.zig").Atom;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const StorageMode = member.StorageMode;
const Member = member.Member;

pub const PropertyMember = Member("Property", 19, struct {
    pub inline fn init(self: *MemberBase, args: *Tuple, kwargs: ?*Dict) !void {
        const kwlist = [_:null][*c]const u8{
            "fget",
            "fset",
            "fdel",
            "cached",
        };
        var fget: ?*Object = null;
        var fset: ?*Object = null;
        var fdel: ?*Object = null;
        var cached: bool = false;
        try py.parseTupleAndKeywords(args, kwargs, "|OOOp", @ptrCast(&kwlist), .{ &fget, &fset, &fdel, &cached });
        if (py.notNone(fget) and !fget.?.isCallable()) {
            try py.typeError("fget must be callable or None", .{});
        }
        if (py.notNone(fset) and !fset.?.isCallable()) {
            try py.typeError("fset must be callable or None", .{});
        }
        if (py.notNone(fdel) and !fdel.?.isCallable()) {
            try py.typeError("fdel must be callable or None", .{});
        }
        if (cached and py.notNone(fset)) {
            try py.typeError("Cached properties are read-only, but a setter was specified", .{});
        }
        self.validate_context = @ptrCast(try Tuple.packNewrefs(.{
            fget orelse py.None(),
            fset orelse py.None(),
            fdel orelse py.None(),
        }));
        if (cached) {
            self.info.storage_mode = .pointer;
        } else {
            self.info.storage_mode = .none;
        }
    }

    // Returns new reference
    pub inline fn get(self: *MemberBase, atom: *Atom) py.Error!*Object {
        const tuple: *Tuple = @ptrCast(self.validate_context.?);
        const fget = try tuple.get(0);
        if (fget.isNone()) {
            const attr = try Str.format("_get_{s}", .{self.name.?.data()});
            defer attr.decref();
            return try atom.callMethod(attr, .{});
        }
        return try fget.callArgs(.{atom});
    }

    pub inline fn getattr(self: *MemberBase, atom: *Atom) py.Error!*Object {
        if (self.info.storage_mode == .pointer) {
            if (atom.slotPtr(self.info.index)) |ptr| {
                if (ptr.*) |v| {
                    return v.newref();
                }
                const v = try get(self, atom);
                ptr.* = v;
                return v.newref();
            }
        }
        return try get(self, atom);
    }

    pub inline fn setattr(self: *MemberBase, atom: *Atom, value: *Object) py.Error!void {
        const tuple: *Tuple = @ptrCast(self.validate_context.?);
        const fset = try tuple.get(1);
        if (fset.isNone()) {
            const attr = try Str.format("_set_{s}", .{self.name.?.data()});
            defer attr.decref();
            const r = try atom.callMethod(attr, .{value});
            defer r.decref();
        } else {
            const r = try fset.callArgs(.{ atom, value });
            defer r.decref();
        }
    }

    pub inline fn delattr(self: *MemberBase, atom: *Atom) py.Error!void {
        const tuple: *Tuple = @ptrCast(self.validate_context.?);
        const fdel = try tuple.get(2);
        if (fdel.isNone()) {
            const attr = try Str.format("_del_{s}", .{self.name.?.data()});
            defer attr.decref();
            const r = try atom.callMethod(attr, .{});
            defer r.decref();
        } else {
            const r = try fdel.callArgs(.{atom});
            defer r.decref();
        }
    }

    pub fn get_fget(self: *PropertyMember) ?*Object {
        const tuple: *Tuple = @ptrCast(self.base.validate_context.?);
        return tuple.getUnsafe(0).?.newref();
    }

    pub fn get_fset(self: *PropertyMember) ?*Object {
        const tuple: *Tuple = @ptrCast(self.base.validate_context.?);
        return tuple.getUnsafe(1).?.newref();
    }

    pub fn get_fdel(self: *PropertyMember) ?*Object {
        const tuple: *Tuple = @ptrCast(self.base.validate_context.?);
        return tuple.getUnsafe(2).?.newref();
    }

    pub fn get_cached(self: *PropertyMember) ?*Object {
        return py.returnBool(self.base.info.storage_mode == .pointer);
    }

    const getset = [_]py.GetSetDef{
        .{ .name = "fget", .get = @ptrCast(&get_fget), .set = null, .doc = "Get the getter function for the property." },
        .{ .name = "fset", .get = @ptrCast(&get_fset), .set = null, .doc = "Get the setter function for the property." },
        .{ .name = "fdel", .get = @ptrCast(&get_fdel), .set = null, .doc = "Get the deleter function for the property." },
        .{ .name = "cached", .get = @ptrCast(&get_cached), .set = null, .doc = "Test the whether or not the property is cached." },
        .{}, // sentinel
    };

    pub const type_slots = [_]py.TypeSlot{
        .{ .slot = py.c.Py_tp_getset, .pfunc = @constCast(@ptrCast(&getset)) },
    };
});

pub const all_members = .{
    PropertyMember,
};

pub fn initModule(mod: *py.Module) !void {
    inline for (all_members) |T| {
        try T.initType();
        errdefer T.deinitType();
        try mod.addObjectRef(T.TypeName, @ptrCast(T.TypeObject.?));
    }
}

pub fn deinitModule(mod: *py.Module) void {
    _ = mod;
    inline for (all_members) |T| {
        T.deinitType();
    }
}
