const py = @import("../api.zig").py;
const std = @import("std");
const Object = py.Object;
const Tuple = py.Tuple;
const Dict = py.Dict;
const Type = py.Type;
const Str = py.Str;
const Atom = @import("../atom.zig").Atom;
const AtomMeta = @import("../atom_meta.zig").AtomMeta;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const Observable = member.Observable;
const Member = member.Member;

// functools.partial
var partial: ?*Object = null;

pub const TypedMember = Member("Typed", 16, struct {

    // Typed takes a single argument kind which is passed to an Typed member
    // Must initalize the validate_context to an TypedMember
    pub inline fn init(self: *MemberBase, args: *Tuple, kwargs: ?*Dict) !void {
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
            self.info.default_mode = .func;
            self.default_context = factory.?.newref();
        } else if (py.notNone(init_args) or py.notNone(init_kwargs)) {
            self.info.default_mode = .func;

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

    pub fn checkTopic(self: *MemberBase, topic: *Str) !Observable {
        if (self.validate_context) |kind| {
            // If kind is an atom subclass
            if (AtomMeta.check(kind)) {
                const meta: *AtomMeta = @ptrCast(kind);
                if (meta.getMember(topic)) |_| {
                    return .yes;
                }
            }
        }
        return .no;
    }

    pub inline fn validate(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
        if (new.isNone() and self.info.optional) {
            return new.newref(); // Ok
        }
        const kind: *Type = @ptrCast(self.validate_context.?);
        if (!new.typeCheck(kind)) {
            try self.validateFail(atom, new, kind.className());
            unreachable;
        }
        return new.newref();
    }
});

pub const ForwardTypedMember = Member("ForwardTyped", 17, struct {
    // Unfortunately this can't check until it's resolved
    pub const observable: Observable = .maybe;

    // Typed takes a single argument kind which is passed to an Typed member
    // Must initalize the validate_context to an TypedMember
    pub inline fn init(self: *MemberBase, args: *Tuple, kwargs: ?*Dict) !void {
        const kwlist = [_:null][*c]const u8{
            "resolve",
            "args",
            "kwargs",
            "factory",
            "optional",
        };
        var resolve_func: *Object = undefined;
        var init_args: ?*Object = null;
        var init_kwargs: ?*Object = null;
        var factory: ?*Object = null;
        var optional: ?*Object = null;
        try py.parseTupleAndKeywords(args, kwargs, "O|OOOO", @ptrCast(&kwlist), .{ &resolve_func, &init_args, &init_kwargs, &factory, &optional });
        if (!resolve_func.isCallable()) {
            return py.typeError("resolve must be a callable that returns the type", .{});
        }
        self.validate_context = resolve_func.newref();
        errdefer py.clear(&self.validate_context);

        if (factory != null and !factory.?.isNone()) {
            if (!factory.?.isCallable()) {
                return py.typeError("factory must be callable", .{});
            }
            self.info.default_mode = .func;
            self.default_context = factory.?.newref();
        } else if (py.notNone(init_args) or py.notNone(init_kwargs)) {
            self.info.default_mode = .func;

            const partial_kwargs: *Object = blk: {
                if (init_kwargs) |v| {
                    if (Dict.check(v)) {
                        break :blk v;
                    } else if (!v.isNone()) {
                        return py.typeError("Typed kwargs must be a dict or None, got: {s}", .{v.typeName()});
                    }
                }
                break :blk py.None();
            };

            const partial_args: *Object = blk: {
                if (init_args) |v| {
                    if (Tuple.check(v)) {
                        break :blk v;
                    } else if (!v.isNone()) {
                        return py.typeError("Typed args must be a tuple or None, got: {s}", .{v.typeName()});
                    }
                }
                break :blk py.None();
            };
            // Make a tuple of (args, kwargs) to call with the resolved type
            self.default_context = @ptrCast(try Tuple.packNewrefs(.{ partial_args, partial_kwargs }));
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

    pub fn resolve(self: *MemberBase, atom: *Atom) !void {
        if (self.validate_context == null) {
            return py.systemError("Invalid resolve context", .{});
        }
        // Call the resolver
        const resolver = self.validate_context.?;
        const kind = try resolver.callArgs(.{});
        defer kind.decref();
        if (!Type.check(kind)) {
            return self.validateFail(atom, kind, "type");
        }

        // If the default context is a tuple of args, kwargs, make a partial
        // with the resolved type
        if (py.notNone(self.default_context) and Tuple.check(self.default_context.?)) {
            const tuple: *Tuple = @ptrCast(self.default_context.?);
            // These may be none
            const args = tuple.getUnsafe(0).?;
            const kwargs = tuple.getUnsafe(1).?;
            const new_args = if (args.isNone()) try Tuple.packNewrefs(.{kind}) else try Tuple.prepend(@ptrCast(args), kind);
            defer new_args.decref();
            py.xsetref(&self.default_context, try partial.?.call(new_args, if (kwargs.isNone()) null else @ptrCast(kwargs)));
        }

        // Replace the resolver with the kind
        py.xsetref(&self.validate_context, kind.newref());
        self.info.resolved = true;
    }

    pub fn default(self: *MemberBase, atom: *Atom) !*Object {
        if (!self.info.resolved) {
            try resolve(self, atom);
        }
        return MemberBase.default(self, @This(), atom);
    }

    pub inline fn validate(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
        if (new.isNone() and self.info.optional) {
            return new.newref(); // Ok
        }
        if (!self.info.resolved) {
            try resolve(self, atom);
        }
        const kind: *Type = @ptrCast(self.validate_context.?);
        if (!new.typeCheck(kind)) {
            try self.validateFail(atom, new, kind.className());
            unreachable;
        }
        return new.newref();
    }
});

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
