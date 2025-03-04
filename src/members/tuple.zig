const py = @import("../api.zig").py;
const std = @import("std");
const Object = py.Object;
const Tuple = py.Tuple;
const Dict = py.Dict;
const Atom = @import("../atom.zig").Atom;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const Member = member.Member;
const InstanceMember = @import("instance.zig").InstanceMember;

pub const TupleMember = Member("Tuple", 15, struct {

    // Tuple takes an optional item, default, and factory
    pub fn init(self: *MemberBase, args: *Tuple, kwargs: ?*Dict) !void {
        const kwlist = [_:null][*c]const u8{
            "item",
            "default",
            "factory",
        };
        var item: ?*Object = null;
        var default_value: ?*Object = null;
        var default_factory: ?*Object = null;
        try py.parseTupleAndKeywords(args, kwargs, "|OOO", @ptrCast(&kwlist), .{ &item, &default_value, &default_factory });

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
            if (!Tuple.check(default_value.?)) {
                return py.typeError("Tuple default must be a tuple", .{});
            }
            self.default_context = default_value.?.newref();
        } else {
            self.default_context = @ptrCast(try Tuple.new(0));
        }
        errdefer py.clear(&self.default_context);
        errdefer py.clear(&self.validate_context);
        if (item) |kind| {
            // TODO: support any member
            if (MemberBase.check(kind)) {
                self.validate_context = kind.newref();
            } else if (!kind.isNone()) {
                self.validate_context = try InstanceMember.TypeObject.?.callArgs(.{kind});
            }
            if (self.validate_context) |context| {
                try self.bindValidatorMember(@ptrCast(context), member.item_str.?);
            }
        }
    }

    pub fn coerce(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
        if (!Tuple.check(new)) {
            try self.validateFail(atom, new, "tuple");
            unreachable;
        }
        if (self.validate_context) |context| {
            const tuple: *Tuple = @ptrCast(new);
            const instance: *MemberBase = @ptrCast(context);
            const n = try tuple.size();
            const copy = try Tuple.new(n);
            errdefer copy.decref();
            for (0..n) |i| {
                copy.setUnsafe(i, try instance.validate(atom, py.None(), tuple.getUnsafe(i).?));
            }
            return @ptrCast(copy);
        }
        return new.newref();
    }
});

pub const all_types = .{
    TupleMember,
};

pub fn initModule(mod: *py.Module) !void {
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
}
