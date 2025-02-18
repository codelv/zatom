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

pub const TupleMember = Member("Tuple", struct {

    // Tuple takes an optional item and default
    pub fn init(self: *MemberBase, args: *Tuple, kwargs: ?*Dict) !void {
        const kwlist = [_:null][*c]const u8{
            "item",
            "default",
        };
        var item: ?*Object = null;
        var default_value: ?*Object = null;
        try py.parseTupleAndKeywords(args, kwargs, "|OO", @ptrCast(&kwlist), .{ &item, &default_value });

        if (py.notNone(default_value)) {
            if (Tuple.check(default_value.?)) {
                self.default_context = default_value.?.newref();
            } else {
                return py.typeError("Tuple default must be a tuple", .{});
            }
        } else {
            self.default_context = @ptrCast(try Tuple.new(0));
        }
        errdefer py.clear(&self.default_context);

        if (item) |kind| {
            // TODO: support any member
            if (InstanceMember.check(kind)) {
                self.validate_context = kind.newref();
            } else if (!kind.isNone()) {
                self.validate_context = try InstanceMember.TypeObject.?.callArgs(.{kind});
            }
        }
    }

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (!Tuple.check(new)) {
            return self.validateFail(atom, new, "tuple");
        }
        if (self.validate_context) |context| {
            const tuple: *Tuple = @ptrCast(new);
            const instance: *InstanceMember = @ptrCast(context);
            const n = try tuple.size();
            for (0..n) |i| {
                try instance.validate(atom, py.None(), try tuple.get(i));
            }
        }
    }
});

const all_types = .{
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
