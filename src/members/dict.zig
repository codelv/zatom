const py = @import("../api.zig").py;
const std = @import("std");
const Object = py.Object;
const Tuple = py.Tuple;
const Dict = py.Dict;
const AtomBase = @import("../atom.zig").AtomBase;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const Member = member.Member;
const InstanceMember = @import("instance.zig").InstanceMember;

pub const DictMember = Member("Dict", struct {

    // Dict takes an optional item, default, and factory
    pub fn init(self: *MemberBase, args: *Tuple, kwargs: ?*Dict) !void {
        const kwlist = [_:null][*c]const u8{
            "key",
            "value",
            "default",
            "factory",
        };
        var key_kind: ?*Object = null;
        var value_kind: ?*Object = null;
        var default_value: ?*Object = null;
        var default_factory: ?*Object = null;
        try py.parseTupleAndKeywords(args, kwargs, "|OOOO", @ptrCast(&kwlist), .{ &key_kind, &value_kind, &default_value, &default_factory });

        if (py.notNone(default_value) and py.notNone(default_factory)) {
            return py.typeError("Cannot use both a default and a factory function", .{});
        }

        if (py.notNone(default_factory)) {
            if (!default_factory.?.isCallable()) {
                return py.typeError("factory must be a callable that returns the default value", .{});
            }
            self.info.default_mode = .call;
            self.default_context = default_factory.?.newref();
        } else if (py.notNone(default_value)) {
            if (!Dict.check(default_value.?)) {
                return py.typeError("Dict default must be a dict", .{});
            }
            self.default_context = default_value.?.newref();
        } else {
            self.default_context = @ptrCast(try Dict.new());
        }
        errdefer py.clear(&self.default_context);
        errdefer py.clear(&self.validate_context);

        if (py.notNone(key_kind) or py.notNone(value_kind)) {
            const key_member = blk: {
                if (py.notNone(key_kind)) {
                    if (MemberBase.check(key_kind.?)) {
                        break :blk key_kind.?.newref();
                    }
                    break :blk try InstanceMember.TypeObject.?.callArgs(.{key_kind.?});
                }
                break :blk py.returnNone();
            };
            defer key_member.decref();

            const value_member = blk: {
                if (py.notNone(value_kind)) {
                    if (MemberBase.check(value_kind.?)) {
                        break :blk value_kind.?.newref();
                    }
                    break :blk try InstanceMember.TypeObject.?.callArgs(.{value_kind.?});
                }
                break :blk py.returnNone();
            };
            defer value_member.decref();

            self.validate_context = @ptrCast(try Tuple.packNewrefs(.{key_member, value_member}));
            if (!key_member.isNone()){
                try self.bindValidatorMember(@ptrCast(key_member), member.key_str.?);
            }
            if (!value_member.isNone()) {
                try self.bindValidatorMember(@ptrCast(value_member), member.value_str.?);
            }
        }

    }

    pub fn defaultStatic(self: *MemberBase, _: *AtomBase) !*Object {
        if (self.default_context) |value| {
            const default_value: *Dict = @ptrCast(value);
            return @ptrCast(try default_value.copy());
        }
        try py.systemError("default context missing", .{});
        unreachable;
    }

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (!Dict.check(new)) {
            return self.validateFail(atom, new, "dict");
        }
        if (self.validate_context) |context| {
            const tuple: *Tuple = @ptrCast(context);
            const key_member = try tuple.get(0);
            const value_member = try tuple.get(1);
            const dict: *Dict = @ptrCast(new);
            const key_val = if (key_member.isNone()) null else try member.dynamicValidate(@ptrCast(key_member));
            const value_val = if (value_member.isNone()) null else try member.dynamicValidate(@ptrCast(value_member));

            var pos: isize = 0;
            if (key_val != null and value_val != null) {
                while (dict.next(&pos)) |entry| {
                    // entry is borrowed, do not decref
                    try key_val.?(@ptrCast(key_member), atom, py.None(), entry.key);
                    try value_val.?(@ptrCast(value_member), atom, py.None(), entry.value);
                }
            } else if (key_val) |validator| {
                while (dict.next(&pos)) |entry| {
                    // entry is borrowed, do not decref
                    try validator(@ptrCast(key_member), atom, py.None(), entry.key);
                }
            } else if (value_val) |validator| {
                while (dict.next(&pos)) |entry| {
                    try validator(@ptrCast(value_member), atom, py.None(), entry.value);
                }
            } else {
                try py.systemError("internal validation error", .{});
                unreachable;
            }
        }
    }
});

pub const all_members = .{
    DictMember,
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

