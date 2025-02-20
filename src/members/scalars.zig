const py = @import("../api.zig").py;
const std = @import("std");
const Object = py.Object;
const AtomBase = @import("../atom.zig").AtomBase;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const StorageMode = member.StorageMode;
const Member = member.Member;

var empty_str: ?*py.Str = null;
var empty_bytes: ?*py.Bytes = null;

// Does no validation at all
pub const ValueMember = Member("Value", struct {
    pub inline fn initDefault() !?*Object {
        return py.returnNone();
    }
});

pub const CallableMember = Member("Callable", struct {
    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (!new.isCallable()) {
            return self.validateFail(atom, new, "callable");
        }
    }
});

pub const BoolMember = Member("Bool", struct {
    pub const storage_mode: StorageMode = .static;
    pub const default_bitsize = 1;

    pub inline fn initDefault() !?*Object {
        return py.returnFalse();
    }

    pub inline fn writeSlot(_: *MemberBase, _: *AtomBase, value: *Object) py.Error!usize {
        return @intFromBool(value == py.True());
    }

    pub inline fn readSlot(_: *MemberBase, _: *AtomBase, data: usize) py.Error!?*Object {
        return py.returnBool(data != 0);
    }

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (!py.Bool.check(new)) {
            return self.validateFail(atom, new, "bool");
        }
    }
});

pub const IntMember = Member("Int", struct {
    pub inline fn initDefault() !?*Object {
        return @ptrCast(try py.Int.new(0));
    }
    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (!py.Int.check(new)) {
            return self.validateFail(atom, new, "int");
        }
    }
});

pub const FloatMember = Member("Float", struct {
    pub inline fn initDefault() !?*Object {
        return @ptrCast(try py.Float.new(0.0));
    }
    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (!py.Float.check(new)) {
            return self.validateFail(atom, new, "float");
        }
    }
});

pub const StrMember = Member("Str", struct {
    pub inline fn initDefault() !?*Object {
        return @ptrCast(empty_str.?.newref());
    }

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) !void {
        if (!py.Str.check(new)) {
            return self.validateFail(atom, new, "str");
        }
    }
});

pub const BytesMember = Member("Bytes", struct {
    pub inline fn initDefault() !?*Object {
        return @ptrCast(empty_bytes.?.newref());
    }

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (!py.Bytes.check(new)) {
            return self.validateFail(atom, new, "bytes");
        }
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
