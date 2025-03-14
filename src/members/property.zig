const py = @import("py");
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
        var cached: c_int = 0;
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
        if (cached != 0 and py.notNone(fset)) {
            try py.typeError("Cached properties are read-only, but a setter was specified", .{});
        }
        self.setValidateContext(.default, @ptrCast(try Tuple.packNewrefs(.{
            fget orelse py.None(),
            fset orelse py.None(),
            fdel orelse py.None(),
        })));
        if (cached != 0) {
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
            const attr = try Str.new("_get_{s}", .{self.name.?.data()});
            defer attr.decref();
            return try atom.callMethod(attr, .{});
        }
        return try fget.callArgs(.{atom});
    }

    pub inline fn getattr(self: *MemberBase, atom: *Atom) py.Error!*Object {
        if (self.validate_context == null) {
            try py.systemError("Invalid validate context", .{});
        }
        if (self.info.storage_mode == .pointer) {
            const ptr = try atom.slotPtr(@ptrCast(self));
            if (ptr.* == null) {
                ptr.* = try get(self, atom);
            }
            return ptr.*.?.newref();
        }
        return try get(self, atom);
    }

    pub inline fn setattr(self: *MemberBase, atom: *Atom, value: *Object) py.Error!void {
        if (self.validate_context == null) {
            try py.systemError("Invalid validate context", .{});
        }
        const tuple: *Tuple = @ptrCast(self.validate_context.?);
        const fset = try tuple.get(1);
        if (fset.isNone()) {
            const attr = try Str.new("_set_{s}", .{self.name.?.data()});
            defer attr.decref();
            const r = try atom.callMethod(attr, .{value});
            defer r.decref();
        } else {
            const r = try fset.callArgs(.{ atom, value });
            defer r.decref();
        }
    }

    pub inline fn delattr(self: *MemberBase, atom: *Atom) py.Error!void {
        if (self.validate_context == null) {
            try py.systemError("Invalid validate context", .{});
        }
        const tuple: *Tuple = @ptrCast(self.validate_context.?);
        const fdel = try tuple.get(2);
        if (fdel.isNone()) {
            const attr = try Str.new("_del_{s}", .{self.name.?.data()});
            defer attr.decref();
            const r = try atom.callMethod(attr, .{});
            defer r.decref();
        } else {
            const r = try fdel.callArgs(.{atom});
            defer r.decref();
        }
    }

    pub fn get_fget(self: *PropertyMember) ?*Object {
        if (self.base.validate_context) |context| {
            const tuple: *Tuple = @ptrCast(context);
            const f = tuple.get(0) catch return null;
            return f.newref();
        }
        return py.returnNone();
    }

    pub fn get_fset(self: *PropertyMember) ?*Object {
        if (self.base.validate_context) |context| {
            const tuple: *Tuple = @ptrCast(context);
            const f = tuple.get(1) catch return null;
            return f.newref();
        }
        return py.returnNone();
    }

    pub fn get_fdel(self: *PropertyMember) ?*Object {
        if (self.base.validate_context) |context| {
            const tuple: *Tuple = @ptrCast(context);
            const f = tuple.get(2) catch return null;
            return f.newref();
        }
        return py.returnNone();
    }

    pub fn get_cached(self: *PropertyMember) ?*Object {
        return py.returnBool(self.base.info.storage_mode == .pointer);
    }

    pub fn set_getter(self: *PropertyMember, func: *Object) ?*Object {
        if (!func.isCallable()) {
            return py.typeErrorObject(null, "Getter must be callable", .{});
        }
        if (self.base.validate_context == null) {
            return py.systemErrorObject(null, "Invalid validate context", .{});
        }
        const tuple: *Tuple = @ptrCast(self.base.validate_context.?);
        tuple.set(0, func.newref()) catch return null;
        return func.newref();
    }

    pub fn set_setter(self: *PropertyMember, func: *Object) ?*Object {
        if (!func.isCallable()) {
            return py.typeErrorObject(null, "Setter must be callable", .{});
        }
        if (self.base.validate_context == null) {
            return py.systemErrorObject(null, "Invalid validate context", .{});
        }
        const tuple: *Tuple = @ptrCast(self.base.validate_context.?);
        tuple.set(1, func.newref()) catch return null;
        return func.newref();
    }

    pub fn set_deleter(self: *PropertyMember, func: *Object) ?*Object {
        if (!func.isCallable()) {
            return py.typeErrorObject(null, "Deleter must be callable", .{});
        }
        if (self.base.validate_context == null) {
            return py.systemErrorObject(null, "Invalid validate context", .{});
        }
        const tuple: *Tuple = @ptrCast(self.base.validate_context.?);
        tuple.set(2, func.newref()) catch return null;
        return func.newref();
    }

    pub fn reset(self: *PropertyMember, atom: *Atom) ?*Object {
        return resetOrError(self, atom) catch null;
    }

    pub fn resetOrError(self: *PropertyMember, atom: *Atom) !*Object {
        if (!atom.typeCheckSelf()) {
            try py.typeError("Invalid arguments. Signature is reset(atom: Atom)", .{});
        }
        // TODO: Support ChangeType.PROPERTY
        if (self.base.shouldNotify(atom)) {
            const old = blk: {
                if (self.base.info.storage_mode == .pointer) {
                    const ptr = try atom.slotPtr(@ptrCast(self));
                    break :blk ptr.* orelse py.None();
                }
                break :blk py.None();
            };
            // Get new value
            const new = try get(@ptrCast(self), atom);
            defer new.decref();
            if (old != new) {
                // Create change dict
                var change = try Dict.new();
                defer change.decref();
                try change.set(@ptrCast(member.type_str.?), @ptrCast(member.property_str.?));
                try change.set(@ptrCast(member.object_str.?), @ptrCast(atom));
                try change.set(@ptrCast(member.name_str.?), @ptrCast(self.base.name.?));
                try change.set(@ptrCast(member.oldvalue_str.?), old);
                try change.set(@ptrCast(member.value_str.?), new);

                try self.base.notifyChange(atom, change, .PROPERTY);

                if (self.base.info.storage_mode == .pointer) {
                    // If cached, update slot with new value
                    const ptr = try atom.slotPtr(@ptrCast(self));
                    py.xsetref(ptr, new.newref());
                }
            }
        }
        return py.returnNone();
    }

    const getset = [_]py.GetSetDef{
        .{ .name = "fget", .get = @ptrCast(&get_fget), .set = null, .doc = "Get the getter function for the property." },
        .{ .name = "fset", .get = @ptrCast(&get_fset), .set = null, .doc = "Get the setter function for the property." },
        .{ .name = "fdel", .get = @ptrCast(&get_fdel), .set = null, .doc = "Get the deleter function for the property." },
        .{ .name = "cached", .get = @ptrCast(&get_cached), .set = null, .doc = "Test the whether or not the property is cached." },
        .{}, // sentinel
    };

    const methods = [_]py.MethodDef{
        .{ .ml_name = "getter", .ml_meth = @constCast(@ptrCast(&set_getter)), .ml_flags = py.c.METH_O, .ml_doc = "Use the given function as the property getter." },
        .{ .ml_name = "setter", .ml_meth = @constCast(@ptrCast(&set_setter)), .ml_flags = py.c.METH_O, .ml_doc = "Use the given function as the property setter." },
        .{ .ml_name = "deleter", .ml_meth = @constCast(@ptrCast(&set_deleter)), .ml_flags = py.c.METH_O, .ml_doc = "Use the given function as the property deleter." },
        .{ .ml_name = "reset", .ml_meth = @constCast(@ptrCast(&reset)), .ml_flags = py.c.METH_O, .ml_doc = "Reset the cached value of the property. If not cached this is a no-op." },
        .{}, // sentinel
    };

    pub const type_slots = [_]py.TypeSlot{
        .{ .slot = py.c.Py_tp_getset, .pfunc = @constCast(@ptrCast(&getset)) },
        .{ .slot = py.c.Py_tp_methods, .pfunc = @constCast(@ptrCast(&methods)) },
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
