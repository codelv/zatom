const py = @import("../api.zig").py;
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

pub const TypedMember = Member("Typed", struct {
    // Typed takes a single argument kind which is passed to an Typed member
    // Must initalize the validate_context to an TypedMember
    pub fn init(self: *MemberBase, args: *Tuple, kwargs: ?*Dict) !void {
        const kwlist = [_:null][*c]const u8{
            "kind",
            "args",
            "kwargs",
            "factory",
            "optional",
        };
        var kind: *Object = undefined;
        var init_args: ?*Object = null;
        var init_kwargs: ?*Object = null;
        var factory: ?*Object = null;
        var optional: ?*Object = null;
        try py.parseTupleAndKeywords(args, kwargs, "O|OOOO", @ptrCast(&kwlist), .{ &kind, &init_args, &init_kwargs, &factory, &optional });
        if (!Type.check(kind)) {
            return py.typeError("kind must be a type", .{});
        }
        self.validate_context = kind.newref();
        errdefer py.clear(&self.validate_context);

        if (factory != null and !factory.?.isNone()) {
            if (!factory.?.isCallable()) {
                return py.typeError("factory must be callable", .{});
            }
            self.info.default_mode = .call;
            self.default_context = factory.?.newref();
        } else if (py.notNone(init_args) or py.notNone(init_kwargs)) {
            self.info.default_mode = .call;

            const partial_kwargs: ?*Dict = blk: {
                if (init_kwargs) |v| {
                    if (Dict.check(v)) {
                        break :blk @ptrCast(v);
                    } else if (!v.isNone()) {
                        return py.typeError("Typed kwargs must be a dict or None, got: {s}", .{v.typeName()});
                    }
                }
                break :blk null;
            };

            const partial_args: *Tuple = blk: {
                if (init_args) |v| {
                    if (Tuple.check(v)) {
                        break :blk try Tuple.prepend(@ptrCast(v), kind);
                    } else if (!v.isNone()) {
                        return py.typeError("Typed args must be a tuple or None, got: {s}", .{v.typeName()});
                    }
                }
                break :blk try Tuple.packNewrefs(.{kind});
            };
            defer partial_args.decref();
            self.default_context = try partial.?.call(partial_args, partial_kwargs);
        } else {
            self.default_context = py.returnNone();
        }

        // If a factory or init args were provided set to to not optional
        // Unless explicitly defined as optional or not
        if (py.notNone(optional)) {
            self.info.optional = optional.?.isTrue();
        } else {
            self.info.optional = self.info.default_mode == .static;
        }
    }

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (new.isNone() and self.info.optional) {
            return; // Ok
        }
        const kind: *Type = @ptrCast(self.validate_context.?);
        if (!new.typeCheck(kind)) {
            return self.validateFail(atom, new, kind.className());
        }
    }
});

pub const ForwardTypedMember = Member("ForwardTyped", struct {});

pub const all_members = .{
    TypedMember,
    ForwardTypedMember,
};

pub fn initModule(mod: *py.Module) !void {
    const functools = try py.importModule("functools");
    defer functools.decref();
    partial = try functools.getAttrString("partial");
    errdefer py.clear(&partial);

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
    py.clear(&partial);
}
