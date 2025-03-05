const py = @import("../api.zig").py;
const std = @import("std");
const Object = py.Object;
const Atom = @import("../atom.zig").Atom;
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
    pub inline fn validate(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
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

    pub inline fn writeSlotStatic(_: *MemberBase, _: *Atom, value: *Object) py.Error!usize {
        return @intFromBool(value == py.True());
    }

    pub inline fn readSlotStatic(_: *MemberBase, _: *Atom, data: usize) py.Error!?*Object {
        return py.returnBool(data != 0);
    }

    pub inline fn validate(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
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
    pub inline fn validate(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
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
    pub inline fn coerce(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
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

    pub inline fn validate(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
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

    pub inline fn validate(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
        if (!py.Bytes.check(new)) {
            try self.validateFail(atom, new, "bytes");
            unreachable;
        }
        return new.newref();
    }
});

pub const ConstantMember = Member("Constant", 19, struct {
    pub fn init(self: *MemberBase, args: *py.Tuple, kwargs: ?*py.Dict) !void {
        const kwlist = [_:null][*c]const u8{
            "default",
            "factory",
            "kind",
        };
        var default: ?*Object = null;
        var kind: ?*Object = null;
        var factory: ?*Object = null;

        try py.parseTupleAndKeywords(args, kwargs, "|OOO", @ptrCast(&kwlist), .{ &default, &factory, &kind });
        if (py.notNone(kind)) {
            try self.validateTypeOrTupleOfTypes(kind.?);
            self.validate_context = kind.?.newref();
        }

        if (py.notNone(factory)) {
            if (!factory.?.isCallable()) {
                return py.typeError("factory must be callable", .{});
            }
            self.info.default_mode = .func;
            self.default_context = factory.?.newref();
        } else if (default) |v| {
            self.default_context = v.newref();
        } else {
            self.default_context = py.returnNone();
        }
    }

    pub inline fn validate(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
        if (self.validate_context) |context| {
            if (!try new.isInstance(context)) {
                if (py.Tuple.check(context)) {
                    const types_str = try context.str();
                    defer types_str.decref();
                    try self.validateFail(atom, new, types_str.data());
                } else {
                    try self.validateFail(atom, new, py.Type.className(@ptrCast(context)));
                }
                unreachable;
            }
        }
        return new.newref();
    }

    pub inline fn setattr(self: *MemberBase, atom: *Atom, _: *Object) py.Error!void {
        try py.typeError("The value of a constant member '{s}' on the '{s}' object cannot be changed.", .{
            self.name.?.data(),
            atom.typeName(),
        });
    }

    pub inline fn delattr(self: *MemberBase, atom: *Atom) py.Error!void {
        try py.typeError("The value of a constant member '{s}' on the '{s}' object cannot be deleted.", .{
            self.name.?.data(),
            atom.typeName(),
        });
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
    ConstantMember,
};

pub fn initModule(mod: *py.Module) !void {
    empty_str = try py.Str.internFromString("");
    errdefer py.clear(&empty_str);
    empty_bytes = try py.Bytes.fromSlice("");
    errdefer py.clear(&empty_bytes);
    inline for (all_members) |T| {
        try T.initType();
        errdefer T.deinitType();
        try mod.addObjectRef(T.TypeName, @ptrCast(T.TypeObject.?));
    }
}

pub fn deinitModule(_: *py.Module) void {
    inline for (all_members) |T| {
        T.deinitType();
    }
    py.clearAll(.{ &empty_str, &empty_bytes });
}
