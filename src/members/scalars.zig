const py = @import("../py.zig");
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
    pub inline fn validate(_: *MemberBase, _: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (!new.isCallable()) {
            _ = py.typeError("Member value must be a callable", .{});
            return error.PyError;
        }
    }
});


pub const BoolMember = Member("Bool", struct {
    pub const storage_mode: StorageMode = .bit;

    pub inline fn initDefault() !?*Object{
        return py.returnFalse();
    }

    comptime {
        std.debug.assert(@sizeOf(*usize) == @sizeOf(*Object));
    }

    pub inline fn writeSlot(self: *MemberBase, _: *AtomBase, slot: *?*Object, value: *Object) py.Error!member.Ownership {
        const mask = @as(usize, 1) << self.info.bit;
        const ptr: *usize = @ptrCast(slot);
        if (value == py.True()) {
            ptr.* |= mask;
        } else {
            ptr.* &= ~mask;
        }
        return .borrowed;
    }

    pub inline fn deleteSlot(self: *MemberBase, _: *AtomBase, slot: *?*Object) void {
        const ptr: *usize = @ptrCast(slot);
        const mask = @as(usize, 1) << self.info.bit;
        ptr.* &= ~mask;
    }

    pub inline fn readSlot(self: *MemberBase, _: *AtomBase, slot: *?*Object) py.Error!?*Object {
        const ptr: *usize = @ptrCast(slot);
        const mask = @as(usize, 1) << self.info.bit;
        return py.returnBool(ptr.* & mask != 0);
    }

    pub inline fn validate(_: *MemberBase, _: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (!py.Bool.check(new)) {
            _ = py.typeError("Member must be a bool", .{});
            return error.PyError;
        }
    }
});



pub const IntMember = Member("Int", struct {
    pub inline fn initDefault() !?*Object{
        return @ptrCast(try py.Int.new(0));
    }
    pub inline fn validate(_: *MemberBase, _: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (!py.Int.check(new)) {
            _ = py.typeError("Member must be an int", .{});
            return error.PyError;
        }
    }
});



pub const FloatMember = Member("Float", struct {
    pub inline fn initDefault() !?*Object{
        return @ptrCast(try py.Float.new(0.0));
    }
    pub inline fn validate(_: *MemberBase, _: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (!py.Float.check(new)) {
            _ = py.typeError("Member must be a float", .{});
            return error.PyError;
        }
    }
});


pub const StrMember = Member("Str", struct {
    pub inline fn initDefault() !?*Object {
        return @ptrCast(empty_str.?.newref());
    }

    pub inline fn validate(_: *MemberBase, _: *AtomBase, _: *Object, new: *Object) !void {
        if (!py.Str.check(new)) {
            _ = py.typeError("Member must be a str", .{});
            return error.PyError;
        }
    }
});


pub const BytesMember = Member("Bytes", struct {
    pub inline fn initDefault() !?*Object {
        return @ptrCast(empty_bytes.?.newref());
    }

    pub inline fn validate(_: *MemberBase, _: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (!py.Bytes.check(new)) {
            _ = py.typeError("Member must be bytes", .{});
            return error.PyError;
        }
    }
});

const all_types = .{
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
    inline for (all_types) |T| {
        try T.initType();
        errdefer T.deinitType();
        try mod.addObjectRef(T.TypeName, @ptrCast(T.TypeObject.?));
    }
}

pub fn deinitModule(mod: *py.Module) void {
    _ = mod;
    errdefer py.clear(&empty_str);
    errdefer py.clear(&empty_bytes);
    inline for (all_types) |T| {
        T.deinitType();
    }
}
