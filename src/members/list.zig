const py = @import("../api.zig").py;
const std = @import("std");
const Object = py.Object;
const List = py.List;
const Tuple = py.Tuple;
const Dict = py.Dict;
const AtomBase = @import("../atom.zig").AtomBase;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const Member = member.Member;
const InstanceMember = @import("instance.zig").InstanceMember;

pub const ListMember = Member("List", struct {

    // List takes an optional item, default, and factory
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
            if (!List.check(default_value.?)) {
                return py.typeError("List default must be a list", .{});
            }
            self.default_context = default_value.?.newref();
        } else {
            self.default_context = @ptrCast(try List.new(0));
        }
        errdefer py.clear(&self.default_context);
        errdefer py.clear(&self.validate_context);

        if (item) |kind| {
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

    pub fn defaultStatic(self: *MemberBase, _: *AtomBase) !*Object {
        if (self.default_context) |value| {
            const default_value: *List = @ptrCast(value);
            return @ptrCast(try default_value.copy());
        }
        try py.systemError("default context missing", .{});
        unreachable;
    }

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (!List.check(new)) {
            return self.validateFail(atom, new, "list");
        }
        if (self.validate_context) |context| {
            const obj: *List = @ptrCast(new);
            const instance: *MemberBase = @ptrCast(context);
            const validator = try member.dynamicValidate(instance);

            const iter = try obj.iter();
            while (try iter.next()) |item| {
                defer item.decref();
                try validator(instance, atom, py.None(), item);
            }
        }
    }
});

pub const all_members = .{
    ListMember,
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
