const py = @import("../py.zig");
const Object = py.Object;
const AtomBase = @import("../atom.zig").AtomBase;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const Member = member.Member;

var empty_str: ?*py.Str = null;
var empty_bytes: ?*py.Bytes = null;


pub fn default_none() !?*Object {
    return py.returnNone();
}

pub fn default_false() !?*Object {
    return py.returnFalse();
}

// Does no validation at all
pub const ValueMember =  Member(.{
    .name="Value",
    .default_factory=default_none,
});


pub fn validate_callable(_: *MemberBase, _: *AtomBase, _: *Object, new: *Object) py.Error!void {
    if (!new.isCallable()) {
        _ = py.typeError("Member value must be a callable");
        return error.PyError;
    }
}

pub const CallableMember =  Member(.{
    .name="Callable",
    .validate = validate_callable,
});


pub fn validate_bool(_: *MemberBase, _: *AtomBase, _: *Object, new: *Object) py.Error!void {
    if (!py.Bool.check(new)) {
        _ = py.typeError("Member must be a bool");
        return error.PyError;
    }
}

pub const BoolMember =  Member(.{
    .name="Bool",
    .default_factory=default_false,
    .storage_mode = .bit,
    .validate = validate_bool,
});


pub fn validate_int(_: *MemberBase, _: *AtomBase, _: *Object, new: *Object) py.Error!void {
    if (!py.Int.check(new)) {
        _ = py.typeError("Member must be an int");
        return error.PyError;
    }
}

pub fn default_int() !?*Object {
    return @ptrCast(try py.Int.new(0));
}

pub const IntMember =  Member(.{
    .name="Int",
    .default_factory=default_int,
    .validate = validate_int,
});


pub fn validate_float(_: *MemberBase, _: *AtomBase, _: *Object, new: *Object) py.Error!void {
    if (!py.Float.check(new)) {
        _ = py.typeError("Member must be a float");
        return error.PyError;
    }
}

pub fn default_float() !?*Object {
    return @ptrCast(try py.Float.new(0.0));
}

pub const FloatMember =  Member(.{
    .name="Float",
    .default_factory=default_float,
    .validate = validate_float,
});


pub fn default_str() !?*Object {
    return @ptrCast(empty_str.?.newref());
}

pub fn validate_str(_: *MemberBase, _: *AtomBase, _: *Object, new: *Object) py.Error!void {
    if (!py.Str.check(new)) {
        _ = py.typeError("Member must be a str");
        return error.PyError;
    }
}

pub const StrMember =  Member(.{
    .name="Str",
    .default_factory=default_str,
    .validate = validate_str,
});


pub fn validate_bytes(_: *MemberBase, _: *AtomBase, _: *Object, new: *Object) py.Error!void {
    if (!py.Bytes.check(new)) {
        _ = py.typeError("Member must be bytes");
        return error.PyError;
    }
}

pub const BytesMember =  Member(.{
    .name="Bytes",
    .validate = validate_bytes,
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
        try mod.addObjectRef(T.Spec.name, @ptrCast(T.TypeObject.?));
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
