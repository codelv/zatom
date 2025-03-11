const py = @import("py");
const std = @import("std");
const Object = py.Object;
const Tuple = py.Tuple;
const Dict = py.Dict;
const Str = py.Str;
const Type = py.Type;
const Atom = @import("../atom.zig").Atom;
const AtomMeta = @import("../atom_meta.zig").AtomMeta;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const StorageMode = member.StorageMode;
const Observable = member.Observable;
const Member = member.Member;

// functools.partial
var partial: ?*Object = null;

pub const CoercedMember = Member("Coerced", 18, struct {
    // Like Instance but has a second coercer function
    pub fn init(self: *MemberBase, args: *Tuple, kwargs: ?*Dict) !void {
        const kwlist = [_:null][*c]const u8{
            "kind",
            "args",
            "kwargs",
            "factory",
            "coercer",
        };
        var kind: *Object = undefined;
        var init_args: ?*Object = null;
        var init_kwargs: ?*Object = null;
        var factory: ?*Object = null;
        var coercer: ?*Object = null;
        try py.parseTupleAndKeywords(args, kwargs, "O|OOOO", @ptrCast(&kwlist), .{ &kind, &init_args, &init_kwargs, &factory, &coercer });
        try self.validateTypeOrTupleOfTypes(kind);
        py.xsetref(&self.validate_context, kind.newref());

        const cls = if (Tuple.check(kind)) Tuple.getUnsafe(@ptrCast(kind), 0).? else kind;

        self.info.default_mode = .func;
        if (py.notNone(factory)) {
            if (!factory.?.isCallable()) {
                return py.typeError("factory must be callable", .{});
            }
            py.xsetref(&self.default_context, factory.?.newref());
        } else if (py.notNone(init_args) or py.notNone(init_kwargs)) {
            const partial_kwargs: ?*Dict = blk: {
                if (init_kwargs) |v| {
                    if (Dict.check(v)) {
                        break :blk @ptrCast(v);
                    } else if (!v.isNone()) {
                        return py.typeError("Coerced kwargs must be a dict or None, got: {s}", .{v.typeName()});
                    }
                }
                break :blk null;
            };

            const partial_args: *Tuple = blk: {
                if (init_args) |v| {
                    if (Tuple.check(v)) {
                        break :blk try Tuple.prepend(@ptrCast(v), cls);
                    } else if (!v.isNone()) {
                        return py.typeError("Coerced args must be a tuple or None, got: {s}", .{v.typeName()});
                    }
                }
                break :blk try Tuple.packNewrefs(.{cls});
            };
            defer partial_args.decref();
            py.xsetref(&self.default_context, try partial.?.call(partial_args, partial_kwargs));
        } else {
            py.xsetref(&self.default_context, cls.newref());
        }

        if (py.notNone(coercer)) {
            if (!coercer.?.isCallable()) {
                return py.typeError("Coerced member's coercer must be callable, got: {s}", .{coercer.?.typeName()});
            }
            py.xsetref(&self.coercer_context, coercer.?.newref());
        } else {
            // It's possbile that there is no init args which could be a problem
            py.xsetref(&self.coercer_context, cls.newref());
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
                return .no;
            }
        }
        return .maybe; // Might be but IDK
    }

    pub inline fn coerce(self: *MemberBase, atom: *Atom, _: *Object, new: *Object) py.Error!*Object {
        if (self.validate_context) |kind| {
            if (!try new.isInstance(kind)) {
                // Try to coerce
                if (self.coercer_context) |coercer| {
                    const coerced = try coercer.callArgs(.{new});
                    defer coerced.decref();
                    if (try coerced.isInstance(kind)) {
                        return coerced.newref();
                    }
                }
                if (py.Tuple.check(kind)) {
                    const types_str = try kind.str();
                    defer types_str.decref();
                    try self.validateFail(atom, new, types_str.data());
                } else {
                    try self.validateFail(atom, new, Type.className(@ptrCast(kind)));
                }
                unreachable;
            }
            return new.newref();
        }
        try py.systemError("Invalid validation context", .{});
        unreachable;
    }
});

pub const all_members = .{
    CoercedMember,
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
