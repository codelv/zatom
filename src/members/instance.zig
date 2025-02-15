const py = @import("../py.zig");
const std = @import("std");
const Object = py.Object;
const Tuple = py.Tuple;
const Dict = py.Dict;
const Type = py.Type;
const AtomBase = @import("../atom.zig").AtomBase;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const Member = member.Member;

// functools.partial
var partial: ?*Object = null;

pub const InstanceMember = Member("Instance", struct {
    // Instance takes a single argument kind which is passed to an Instance member
    // Must initalize the validate_context to an InstanceMember
    pub fn init(self: *MemberBase, args: *Tuple, kwargs: ?*Dict) !void {
        const kwlist = [_:null][*c]const u8{
            "kind",
        };
        var kind: *Object = undefined;
        var init_args: ?*Object = null;
        var init_kwargs: ?*Object = null;
        var factory: ?*Object = null;
        var optional: ?*Object = null;
        try py.parseTupleAndKeywords(args, kwargs, "O|OOOO", @ptrCast(&kwlist), .{ &kind, &init_args, &init_kwargs, &factory, &optional });
        try self.validateTypeOrTupleOfTypes(kind);
        self.validate_context = kind.newref();
        errdefer py.clear(&self.validate_context);

        if (factory != null and !factory.?.isNone()) {
            if (!factory.?.isCallable()) {
                _ = py.typeError("factory must be callable", .{});
                return error.PyError;
            }
            self.info.default_mode = .call;
            self.default_context = factory.?.newref();
        } else if (py.notNone(init_args) or py.notNone(init_kwargs)) {
            self.info.default_mode = .call;
            const cls = if (Tuple.check(kind)) try Tuple.get(@ptrCast(kind), 0) else kind;

            const partial_kwargs: ?*Dict = blk: {
                if (init_kwargs) |v| {
                    if (Dict.check(v)) {
                        break :blk @ptrCast(v);
                    } else if (!v.isNone()) {
                        _ = py.typeError("Instance kwargs must be a dict or None, got: {s}", .{v.typeName()});
                        return error.PyError;
                    }
                }
                break :blk null;
            };

            const partial_args: *Tuple = blk: {
                if (init_args) |v| {
                    if (Tuple.check(v)) {
                        break :blk try Tuple.prepend(@ptrCast(v), cls);
                    } else if (!v.isNone()) {
                        _ = py.typeError("Instance args must be a tuple or None, got: {s}", .{v.typeName()});
                        return error.PyError;
                    }
                }
                break :blk try Tuple.pack(.{cls});
            };
            defer partial_args.decref();
            self.default_context = try partial.?.call(partial_args, partial_kwargs);
        } else {
            self.default_context = py.returnNone();
        }

        // TODO: Optional
    }

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!void {
        const context = self.validate_context.?;
        if (!try new.isInstance(context)) {
            // TODO: Improve message
            if (py.Tuple.check(context)) {
                const types_str = try context.str();
                defer types_str.decref();
                return self.validateFail(atom, new, types_str.data());
            } else {
                return self.validateFail(atom, new, context.typeName());
            }
            return error.PyError;
        }
    }
});

pub const ForwardInstanceMember = Member("ForwardInstance", struct {

});



const all_types = .{
    InstanceMember,
    ForwardInstanceMember,
};

pub fn initModule(mod: *py.Module) !void {
    const functools = try py.importModule("functools");
    defer functools.decref();
    partial = try functools.getAttrString("partial");
    errdefer py.clear(&partial);

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
    py.clear(&partial);
}
