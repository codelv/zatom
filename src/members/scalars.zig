const py = @import("py");
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
var inf_str: ?*py.Str = null;
var neg_inf_str: ?*py.Str = null;

// Does no validation at all
pub const ValueMember = Member("Value", 7, struct {
    pub const observable: Observable = .maybe;
    pub inline fn initDefault() !?*Object {
        return py.returnNone();
    }

    pub inline fn validate(self: *MemberBase, atom: *Atom, old: *Object, new: *Object) py.Error!*Object {
        if (self.validate_context) |context| {
            return switch (self.info.validate_mode) {
                .default => new.newref(),
                .call_old_new => try context.callArgs(.{ old, new }),
                .call_object_old_new => try context.callArgs(.{ atom, old, new }),
                .call_name_old_new => try context.callArgs(.{ self.name.?, old, new }),
            };
        }
        return new.newref();
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
                return @ptrCast(try py.Float.fromInt(@ptrCast(new)));
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
            py.xsetref(&self.validate_context, kind.?.newref());
        }

        if (py.notNone(factory)) {
            if (!factory.?.isCallable()) {
                return py.typeError("factory must be callable", .{});
            }
            self.info.default_mode = .func;
            py.xsetref(&self.default_context, factory.?.newref());
        } else {
            self.info.default_mode = .static;
            py.xsetref(&self.default_context, py.returnOptional(default));
        }
    }

    pub inline fn validate(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
        if (self.validate_context) |kind| {
            if (!try new.isInstance(kind)) {
                if (py.Tuple.check(kind)) {
                    const types_str = try kind.str();
                    defer types_str.decref();
                    try self.validateFail(atom, new, types_str.data());
                } else {
                    try self.validateFail(atom, new, py.Type.className(@ptrCast(kind)));
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

pub const RangeMember = Member("Range", 20, struct {
    pub fn init(self: *MemberBase, args: *py.Tuple, kwargs: ?*py.Dict) !void {
        const kwlist = [_:null][*c]const u8{
            "low",
            "high",
            "value",
        };
        var low: ?*Object = null;
        var high: ?*Object = null;
        var value: ?*Object = null;
        try py.parseTupleAndKeywords(args, kwargs, "|OOO", @ptrCast(&kwlist), .{ &low, &high, &value });

        if (py.notNone(value) and !py.Int.check(value.?)) {
            return py.typeError("value must be an int or None", .{});
        }
        if (py.notNone(low) and !py.Int.check(low.?)) {
            return py.typeError("low must be an int or None", .{});
        }
        if (py.notNone(high) and !py.Int.check(high.?)) {
            return py.typeError("low must be an int or None", .{});
        }
        if (py.notNone(low) and py.notNone(high)) {
            if (try Object.compare(low.?, .gt, high.?)) {
                const tmp = low.?;
                low = high.?;
                high = tmp;
            }
        }

        py.xsetref(&self.validate_context, @ptrCast(try py.Tuple.packNewrefs(.{
            low orelse py.None(),
            high orelse py.None(),
        })));

        self.info.default_mode = .static;
        if (py.notNone(value)) {
            py.xsetref(&self.default_context, @ptrCast(value.?.newref()));
        } else if (py.notNone(low)) {
            py.xsetref(&self.default_context, low.?.newref());
        } else if (py.notNone(high)) {
            py.xsetref(&self.default_context, high.?.newref());
        } else {
            py.xsetref(&self.default_context, @ptrCast(try py.Int.new(0)));
        }
    }

    pub inline fn validate(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
        if (!py.Int.check(new)) {
            try self.validateFail(atom, new, "int");
            unreachable;
        }
        if (self.validate_context) |context| {
            const tuple: *py.Tuple = @ptrCast(context);
            const low = tuple.getUnsafe(0).?;
            const high = tuple.getUnsafe(1).?;
            if (!low.isNone() and try new.compare(.lt, low)) {
                try py.valueError("range value for '{s}' of '{s}' is too small", .{
                    self.name.?.data(),
                    atom.typeName(),
                });
            }
            if (!high.isNone() and try new.compare(.gt, high)) {
                try py.valueError("range value for '{s}' of '{s}' is too large", .{
                    self.name.?.data(),
                    atom.typeName(),
                });
            }
            return new.newref();
        }
        try py.systemError("Invalid validation context", .{});
        unreachable;
    }
});

pub const FloatRangeMember = Member("FloatRange", 21, struct {
    pub fn init(self: *MemberBase, args: *py.Tuple, kwargs: ?*py.Dict) !void {
        const kwlist = [_:null][*c]const u8{
            "low",
            "high",
            "value",
            "strict",
        };
        var low: ?*Object = null;
        var high: ?*Object = null;
        var value: ?*Object = null;
        var strict: bool = false;

        try py.parseTupleAndKeywords(args, kwargs, "|OOOp", @ptrCast(&kwlist), .{ &low, &high, &value, &strict });

        var low_value: *py.Float = blk: {
            if (py.notNone(low)) {
                if (py.Float.check(low.?)) {
                    break :blk @ptrCast(low.?.newref());
                } else if (!strict and py.Int.check(low.?)) {
                    break :blk try py.Float.fromInt(@ptrCast(low.?));
                } else {
                    return py.typeError("low must be an float or None", .{});
                }
            } else {
                break :blk try py.Float.fromString(neg_inf_str.?);
            }
        };
        defer low_value.decref();

        var high_value: *py.Float = blk: {
            if (py.notNone(high)) {
                if (py.Float.check(high.?)) {
                    break :blk @ptrCast(high.?.newref());
                } else if (!strict and py.Int.check(high.?)) {
                    break :blk try py.Float.fromInt(@ptrCast(high.?));
                } else {
                    return py.typeError("high must be an float or None", .{});
                }
            } else {
                break :blk try py.Float.fromString(inf_str.?);
            }
        };
        defer high_value.decref();

        if (py.notNone(low) and py.notNone(high)) {
            if (try low_value.compare(.gt, @ptrCast(high_value))) {
                const tmp = low_value;
                low_value = high_value;
                high_value = tmp;
            }
        }
        self.info.coerce = !strict;
        self.info.default_mode = .static;
        py.xsetref(&self.validate_context, @ptrCast(try py.Tuple.packNewrefs(.{ low_value, high_value })));
        if (py.notNone(value)) {
            if (py.Float.check(value.?)) {
                py.xsetref(&self.default_context, value.?.newref());
            } else if (!strict and py.Int.check(value.?)) {
                py.xsetref(&self.default_context, @ptrCast(try py.Float.fromInt(@ptrCast(value.?))));
            } else {
                return py.typeError("value must be an float or None", .{});
            }
        } else if (py.notNone(low)) {
            py.xsetref(&self.default_context, @ptrCast(low_value.newref()));
        } else if (py.notNone(high)) {
            py.xsetref(&self.default_context, @ptrCast(high_value.newref()));
        } else {
            py.xsetref(&self.default_context, @ptrCast(try py.Float.new(0.0)));
        }
    }

    pub inline fn coerce(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
        const coerced: *Object = blk: {
            if (!py.Float.check(new)) {
                if (self.info.coerce and py.Int.check(new)) {
                    break :blk @ptrCast(try py.Float.fromInt(@ptrCast(new)));
                }
                try self.validateFail(atom, new, "float");
                unreachable;
            }
            break :blk new.newref();
        };
        errdefer coerced.decref(); // Only decref if va

        if (self.validate_context) |context| {
            const tuple: *py.Tuple = @ptrCast(context);
            const low = tuple.getUnsafe(0).?;
            const high = tuple.getUnsafe(1).?;
            if (try coerced.compare(.lt, low)) {
                try py.valueError("range value for '{s}' of '{s}' is too small", .{
                    self.name.?.data(),
                    atom.typeName(),
                });
                unreachable;
            }
            if (try coerced.compare(.gt, high)) {
                try py.valueError("range value for '{s}' of '{s}' is too large", .{
                    self.name.?.data(),
                    atom.typeName(),
                });
                unreachable;
            }
            return coerced;
        }
        try py.systemError("Invalid validation context", .{});
        unreachable;
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
    RangeMember,
    FloatRangeMember,
};

pub fn initModule(mod: *py.Module) !void {
    empty_str = try py.Str.internFromString("");
    errdefer py.clear(&empty_str);
    empty_bytes = try py.Bytes.fromSlice("");
    errdefer py.clear(&empty_bytes);

    inf_str = try py.Str.internFromString("inf");
    errdefer py.clear(&inf_str);
    neg_inf_str = try py.Str.internFromString("-inf");
    errdefer py.clear(&neg_inf_str);

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
    py.clearAll(.{ &empty_str, &empty_bytes, &inf_str, &neg_inf_str });
}
