const py = @import("../api.zig").py;
const std = @import("std");
const Object = py.Object;
const AtomBase = @import("../atom.zig").AtomBase;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const StorageMode = member.StorageMode;
const Observable = member.Observable;
const Member = member.Member;

var empty_str: ?*py.Str = null;
var empty_bytes: ?*py.Bytes = null;

// Does no validation at all
pub const ValueMember = Member("Value", 7, struct {
    pub const observable: Observable = .maybe;
    pub inline fn initDefault() !?*Object {
        return py.returnNone();
    }
});

pub const CallableMember = Member("Callable", 8, struct {
    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!*Object {
        if (!new.isCallable()) {
            try self.validateFail(atom, new, "callable");
            unreachable;
        }
        return new.newref();
    }
});

pub const BoolMember = Member("Bool", 9, struct {
    pub const storage_mode: StorageMode = .static;
    pub const default_bitsize = 1;

    pub inline fn initDefault() !?*Object {
        return py.returnFalse();
    }

    pub inline fn writeSlotStatic(_: *MemberBase, _: *AtomBase, value: *Object) py.Error!usize {
        return @intFromBool(value == py.True());
    }

    pub inline fn readSlotStatic(_: *MemberBase, _: *AtomBase, data: usize) py.Error!?*Object {
        return py.returnBool(data != 0);
    }

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!*Object {
        if (!py.Bool.check(new)) {
            try self.validateFail(atom, new, "bool");
            unreachable;
        }
        return new.newref();
    }
});

pub const IntMember = Member("Int", 10, struct {
    pub inline fn initDefault() !?*Object {
        return @ptrCast(try py.Int.new(0));
    }
    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!*Object {
        if (!py.Int.check(new)) {
            try self.validateFail(atom, new, "int");
            unreachable;
        }
        return new.newref();
    }
});

pub const FloatMember = Member("Float", 11, struct {
    pub inline fn initDefault() !?*Object {
        return @ptrCast(try py.Float.new(0.0));
    }
    pub inline fn coerce(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!*Object {
        if (!py.Float.check(new)) {
            if (self.info.coerce and py.Int.check(new)) {
                const value = try py.Int.as(@ptrCast(new), f64);
                return @ptrCast(try py.Float.new(value));
            }
            try self.validateFail(atom, new, "float");
            unreachable;
        }
        return new.newref();
    }
});

pub const StrMember = Member("Str", 12, struct {
    pub inline fn initDefault() !?*Object {
        return @ptrCast(empty_str.?.newref());
    }

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!*Object {
        if (!py.Str.check(new)) {
            try self.validateFail(atom, new, "str");
            unreachable;
        }
        return new.newref();
    }
});

pub const BytesMember = Member("Bytes", 13, struct {
    pub inline fn initDefault() !?*Object {
        return @ptrCast(empty_bytes.?.newref());
    }

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!*Object {
        if (!py.Bytes.check(new)) {
            try self.validateFail(atom, new, "bytes");
            unreachable;
        }
        return new.newref();
    }
});

pub const all_members = .{
    ValueMember,
    CallableMember,
    BoolMember,
    IntMember,
    FloatMember,
    StrMember,
    BytesMember,
};

pub fn initModule(mod: *py.Module) !void {
    empty_str = try py.Str.internFromString("");
    errdefer py.clear(&empty_str);
    inline for (all_members) |T| {
        try T.initType();
        errdefer T.deinitType();
        try mod.addObjectRef(T.TypeName, @ptrCast(T.TypeObject.?));
    }
}

pub fn deinitModule(mod: *py.Module) void {
    _ = mod;
    errdefer py.clear(&empty_str);
    errdefer py.clear(&empty_bytes);
    inline for (all_members) |T| {
        T.deinitType();
    }
}
