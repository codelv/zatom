const py = @import("../api.zig").py;
const std = @import("std");
const Object = py.Object;
const Type = py.Type;
const Set = py.Set;
const Tuple = py.Tuple;
const Dict = py.Dict;
const AtomBase = @import("../atom.zig").AtomBase;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const Member = member.Member;
const InstanceMember = @import("instance.zig").InstanceMember;
const package_name = @import("../api.zig").package_name;

// Set update function
var set_update_method: ?*py.Method = null;

pub const TypedSet = extern struct {
    const Self = @This();
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;

    base: Set,
    validate_context: ?*Tuple = null, // tuple[MemberBase, AtomBase]
    validator: ?MemberBase.Validator = null, // TODO: Consider eliminating this

    pub usingnamespace py.ObjectProtocol(Self);

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *const Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    // --------------------------------------------------------------------------
    // Methods
    // --------------------------------------------------------------------------
    pub fn add(self: *Self, item: *Object) ?*Object {
        self.validateItem(item) catch return null;
        Set.add(@ptrCast(self), @ptrCast(item)) catch return null;
        return py.returnNone();
    }

    pub fn symmetric_difference_update(self: *Self, other: *Object) ?*Object {
        if (Set.checkAny(other)) {
            return self.isub(other);
        }
        const coerced = Set.new(other) catch return null;
        defer coerced.decref();
        return self.isub(@ptrCast(coerced));
    }

    pub fn update(self: *Self, args: *Tuple) ?*Object {
        const n = args.size() catch return null;
        for (0..n) |i| {
            const item = args.getUnsafe(i).?;
            self.validateIterable(item) catch return null;
        }
        const new_args = args.prepend(@ptrCast(self)) catch return null;
        defer new_args.decref();
        return set_update_method.?.call(new_args, null) catch null;
    }

    pub fn iand(self: *Self, other: *Object) ?*Object {
        if (!Set.checkAny(other))
            return py.returnNotImplemented();
        self.validateIterable(other) catch return null;
        return @ptrCast(py.c.PySet_Type.tp_as_number.*.nb_inplace_and.?(@ptrCast(self), @ptrCast(other)));
    }

    pub fn isub(self: *Self, other: *Object) ?*Object {
        if (!Set.checkAny(other))
            return py.returnNotImplemented();
        self.validateIterable(other) catch return null;
        return @ptrCast(py.c.PySet_Type.tp_as_number.*.nb_inplace_subtract.?(@ptrCast(self), @ptrCast(other)));
    }

    pub fn ixor(self: *Self, other: *Object) ?*Object {
        if (!Set.checkAny(other))
            return py.returnNotImplemented();
        self.validateIterable(other) catch return null;
        return @ptrCast(py.c.PySet_Type.tp_as_number.*.nb_inplace_xor.?(@ptrCast(self), @ptrCast(other)));
    }

    pub fn ior(self: *Self, other: *Object) ?*Object {
        if (!Set.checkAny(other))
            return py.returnNotImplemented();
        self.validateIterable(other) catch return null;
        return @ptrCast(py.c.PySet_Type.tp_as_number.*.nb_inplace_or.?(@ptrCast(self), @ptrCast(other)));
    }

    // --------------------------------------------------------------------------
    // Internal api
    // --------------------------------------------------------------------------
    pub fn newNoContext(items: *Object) !*TypedSet {
        return @ptrCast(try TypeObject.?.callArgs(.{items}));
    }

    pub fn newWithContext(items: *Object, validate_member: *MemberBase, atom: *AtomBase) !*TypedSet {
        const validator = try member.dynamicValidate(validate_member);

        // Validate the items
        const iter = try items.iter();
        while (try iter.next()) |item| {
            defer item.decref();
            try validator(validate_member, atom, py.None(), item);
        }

        const context = try Tuple.packNewrefs(.{ validate_member, atom });
        errdefer context.decref();
        const self = try newNoContext(items);
        self.validator = validator;
        self.validate_context = context;
        return @ptrCast(self);
    }

    pub fn hasSameContext(self: *Self, validate_member: ?*Object, atom: *AtomBase) bool {
        if (self.validate_context) |tuple| {
            return (tuple.getUnsafe(0) == validate_member and @as(*AtomBase, @ptrCast(tuple.getUnsafe(1).?)) == atom);
        }
        return validate_member == null;
    }

    pub inline fn validateItem(self: *Self, item: *Object) !void {
        const tuple = self.validate_context orelse return;
        const mem: *MemberBase = @ptrCast(tuple.getUnsafe(0).?);
        const atom: *AtomBase = @ptrCast(tuple.getUnsafe(1).?);
        try self.validator.?(mem, atom, py.None(), item);
    }

    pub fn validateIterable(self: *Self, items: *Object) !void {
        const tuple = self.validate_context orelse return;
        const mem: *MemberBase = @ptrCast(tuple.getUnsafe(0).?);
        const atom: *AtomBase = @ptrCast(tuple.getUnsafe(1).?);
        const iter = try items.iter();
        while (try iter.next()) |item| {
            defer item.decref();
            try self.validator.?(mem, atom, py.None(), item);
        }
    }

    // --------------------------------------------------------------------------
    // Type definition
    // --------------------------------------------------------------------------
    pub fn dealloc(self: *Self) void {
        self.gcUntrack();
        py.clear(&self.validate_context);
        py.c.PySet_Type.tp_dealloc.?(@ptrCast(self));
    }

    pub fn clear(self: *Self) c_int {
        py.clear(&self.validate_context);
        return py.c.PySet_Type.tp_clear.?(@ptrCast(self));
    }

    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        const r = py.visit(self.validate_context, visit, arg);
        if (r != 0)
            return r;
        return py.c.PySet_Type.tp_traverse.?(@ptrCast(self), visit, arg);
    }

    const methods = [_]py.MethodDef{
        .{ .ml_name = "add", .ml_meth = @constCast(@ptrCast(&add)), .ml_flags = py.c.METH_O, .ml_doc = "Add an item to the set." },
        .{ .ml_name = "symmetric_difference_update", .ml_meth = @constCast(@ptrCast(&symmetric_difference_update)), .ml_flags = py.c.METH_O, .ml_doc = "Update the set, keeping only elements found in either set, but not in both." },
        .{ .ml_name = "update", .ml_meth = @constCast(@ptrCast(&update)), .ml_flags = py.c.METH_VARARGS, .ml_doc = "Update the set, adding elements from all others." },
        .{}, // sentinel
    };

    const type_slots = [_]py.TypeSlot{
        //.{ .slot = py.c.Py_tp_new, .pfunc = @constCast(@ptrCast(&new)) },
        .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
        .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
        .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
        .{ .slot = py.c.Py_nb_inplace_and, .pfunc = @constCast(@ptrCast(&iand)) },
        .{ .slot = py.c.Py_nb_inplace_subtract, .pfunc = @constCast(@ptrCast(&isub)) },
        .{ .slot = py.c.Py_nb_inplace_xor, .pfunc = @constCast(@ptrCast(&ixor)) },
        .{ .slot = py.c.Py_nb_inplace_or, .pfunc = @constCast(@ptrCast(&ior)) },
        .{ .slot = py.c.Py_tp_methods, .pfunc = @constCast(@ptrCast(&methods)) },
        .{}, // sentinel
    };

    pub var TypeSpec = py.TypeSpec{
        .name = package_name ++ ".TypedSet",
        .basicsize = @sizeOf(Self),
        .flags = (py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_HAVE_GC),
        .slots = @constCast(@ptrCast(&type_slots)),
    };

    pub fn initType() !void {
        if (TypeObject != null) return;
        TypeObject = try Type.fromSpecWithBases(&TypeSpec, @ptrCast(&py.c.PySet_Type));
    }

    pub fn deinitType() void {
        py.clear(&TypeObject);
    }
};

pub const SetMember = Member("Set", struct {

    // Set takes an optional item, default, and factory
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
            if (!Set.check(default_value.?)) {
                return py.typeError("Set default must be a set", .{});
            }
            self.default_context = default_value.?.newref();
        } else {
            self.default_context = @ptrCast(try Set.new(null));
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

    pub fn defaultStatic(self: *MemberBase, atom: *AtomBase) !*Object {
        if (self.default_context) |default_value| {
            if (self.validate_context) |validate_member| {
                // Do it here or it just gets copied again by the coerce function later
                return @ptrCast(try TypedSet.newWithContext(default_value, @ptrCast(validate_member), atom));
            }
            return @ptrCast(try Set.copy(@ptrCast(default_value))); // Copy the default
        }
        try py.systemError("default context missing", .{});
        unreachable;
    }

    pub fn coerce(self: *MemberBase, atom: *AtomBase, value: *Object) !*Object {
        if (self.validate_context) |validate_member| {
            if (TypedSet.check(value)) {
                const typed_set: *TypedSet = @ptrCast(value);
                if (typed_set.hasSameContext(self.validate_context, atom)) {
                    return value.newref();
                }
            }
            return @ptrCast(try TypedSet.newWithContext(value, @ptrCast(validate_member), atom));
        } else if (Set.checkAny(value)) {
            return value.newref(); // untyped sets do not need coereced
        }
        try self.validateFail(atom, value, "set");
        unreachable;
    }

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (TypedSet.check(new)) {
            return; // Set should already be validated
        }
        if (!Set.check(new)) {
            return self.validateFail(atom, new, "set");
        }
        if (self.validate_context) |context| {
            const obj: *Set = @ptrCast(new);
            // TODO: How expensive is this???
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
    SetMember,
};

pub fn initModule(mod: *py.Module) !void {
    set_update_method = @ptrCast(try Object.getAttrString(@ptrCast(&py.c.PySet_Type), "update"));
    errdefer py.clear(&set_update_method);

    try TypedSet.initType();
    errdefer TypedSet.deinitType();
    try mod.addObjectRef("TypedSet", @ptrCast(TypedSet.TypeObject.?));

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
    TypedSet.deinitType();
    py.clear(&set_update_method);
}
