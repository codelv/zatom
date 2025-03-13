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

var default_str: ?*Str = null;

pub const EnumMember = Member("Enum", 2, struct {
    pub const storage_mode: StorageMode = .static;

    // Instance takes a single argument kind which is passed to an Instance member
    // Must initalize the validate_context to an InstanceMember
    pub fn init(self: *MemberBase, args: *Tuple, kwargs: ?*Dict) !void {
        const n = try args.size();
        if (n < 1) {
            return py.typeError("at least one enum item is required", .{});
        }
        var default_value: *Object = args.getUnsafe(0).?;
        if (kwargs) |kw| {
            if (kw.get(@ptrCast(default_str.?))) |v| {
                if (try args.contains(v)) {
                    default_value = v;
                } else if (!v.isNone()) {
                    return py.typeError("the default provided is not in the enum items", .{});
                }
            } else {
                return py.typeError("only one keyword 'default' is accepted", .{});
            }
        }

        const bitsize = std.math.log2_int_ceil(usize, n);
        if (bitsize > @bitSizeOf(usize)) {
            return py.typeError("bitsize out of range", .{});
        }
        self.info.width = @intCast(bitsize -| 1);
        self.setDefaultContext(.static, default_value.newref());
        self.setValidateContext(.default, @ptrCast(args.newref()));
    }

    pub inline fn writeSlotStatic(self: *MemberBase, _: *Atom, value: *Object) py.Error!usize {
        if (self.validate_context == null) {
            try py.systemError("Invalid validation context", .{});
        }
        const items: *Tuple = @ptrCast(self.validate_context.?);
        return try items.index(value);
    }

    pub inline fn readSlotStatic(self: *MemberBase, _: *Atom, data: usize) py.Error!?*Object {
        if (self.validate_context == null) {
            try py.systemError("Invalid validation context", .{});
        }
        const items: *Tuple = @ptrCast(self.validate_context.?);
        const value = try items.get(data);
        return value.newref();
    }

    pub inline fn validate(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
        if (self.validate_context) |context| {
            const items: *Tuple = @ptrCast(context);
            if (!try items.contains(new)) {
                try py.valueError("invalid enum value for '{s}' of '{s}'. Got '{s}'", .{
                    self.name.?.data(),
                    atom.typeName(),
                    new.typeName(),
                });
                unreachable;
            }
            return new.newref();
        }
        try py.systemError("Invalid validation context", .{});
        unreachable;
    }

    pub fn call(self: *MemberBase, args: *Tuple, kwargs: ?*Dict) ?*Object {
        const kwlist = [_:null][*c]const u8{"item"};
        var new_default: *Object = undefined;
        py.parseTupleAndKeywords(args, kwargs, "O:__call__", @ptrCast(&kwlist), .{&new_default}) catch return null;
        if (self.validate_context == null) {
            return py.systemErrorObject(null, "Invalid validation context", .{});
        }
        const items: *Tuple = @ptrCast(self.validate_context.?);
        if (!(items.contains(new_default) catch return null)) {
            return py.typeErrorObject(null, "invalid enum value", .{});
        }
        const clone = self.cloneOrError() catch return null;
        clone.setDefaultContext(.static, new_default.newref());
        return @ptrCast(clone);
    }

    pub fn get_items(self: *EnumMember) ?*Object {
        return py.returnOptional(self.base.validate_context);
    }

    const getset = [_]py.GetSetDef{
        .{ .name = "items", .get = @ptrCast(&get_items), .set = null, .doc = "Enum items" },
        .{}, // sentinel
    };

    pub const type_slots = [_]py.TypeSlot{
        .{ .slot = py.c.Py_tp_call, .pfunc = @constCast(@ptrCast(&call)) },
        .{ .slot = py.c.Py_tp_getset, .pfunc = @constCast(@ptrCast(&getset)) },
    };
});

pub const all_members = .{
    EnumMember,
};

pub fn initModule(mod: *py.Module) !void {
    default_str = try Str.internFromString("default");
    errdefer py.clear(&default_str);
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
    py.clear(&default_str);
}
