const py = @import("../py.zig");
const std = @import("std");
const Object = py.Object;
const Tuple = py.Tuple;
const Dict = py.Dict;
const Str = py.Str;
const AtomBase = @import("../atom.zig").AtomBase;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const StorageMode = member.StorageMode;
const Member = member.Member;

var default_str: ?*Str = null;

pub const EnumMember = Member("Enum", struct {
    pub const storage_mode: StorageMode = .static;

    // Instance takes a single argument kind which is passed to an Instance member
    // Must initalize the validate_context to an InstanceMember
    pub fn init(self: *MemberBase, args: *Tuple, kwargs: ?*Dict) !void {
        const n = try args.size();
        if (n < 1) {
            _ = py.typeError("at least one enum item is required", .{});
            return error.PyError;
        }
        var default_value: *Object = try args.get(0);
        if (kwargs) |kw| {
            if (kw.get(@ptrCast(default_str.?))) |v| {
                if (try args.contains(v)) {
                    default_value = v;
                } else if (!v.isNone()) {
                    _ = py.typeError("the default provided is not in the enum items", .{});
                    return error.PyError;
                }
            } else {
                _ = py.typeError("only one keyword 'default' is accepted", .{});
                return error.PyError;
            }
        }

        const bitsize = std.math.log2_int_ceil(usize, n);
        if (bitsize == 0 or bitsize > @bitSizeOf(usize)) {
            _ = py.typeError("bitsize out of range", .{});
            return error.PyError;
        }
        self.info.width = @intCast(bitsize - 1);
        self.default_context = default_value.newref();
        self.validate_context = @ptrCast(args.newref());
    }

    pub inline fn writeSlot(self: *MemberBase, _: *AtomBase, value: *Object) py.Error!usize {
        const items: *Tuple = @ptrCast(self.validate_context.?);
        const data = try items.index(value);
        return data;
    }

    pub inline fn readSlot(self: *MemberBase, _: *AtomBase, data: usize) py.Error!?*Object {
        const items: *Tuple = @ptrCast(self.validate_context.?);
        const value = try items.get(data);
        return value.newref();
    }

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!void {
        const items: *Tuple = @ptrCast(self.validate_context.?);
        if (!try items.contains(new)) {
            _ = py.valueError("invalid enum value for '{s}' of '{s}'. Got '{s}'", .{
                self.name.data(),
                atom.typeName(),
                new.typeName(),
            });
            return error.PyError;
        }
    }
});

const all_types = .{
    EnumMember,
};

pub fn initModule(mod: *py.Module) !void {
    default_str = try Str.internFromString("default");
    errdefer py.clear(&default_str);
    inline for (all_types) |T| {
        try T.initType();
        errdefer T.deinitType();
        try mod.addObjectRef(T.TypeName, @ptrCast(T.TypeObject.?));
    }
}

pub fn deinitModule(mod: *py.Module) void {
    _ = mod;
    inline for (all_types) |T| {
        T.deinitType();
    }
    py.clear(&default_str);
}
