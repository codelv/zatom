const py = @import("../api.zig").py;
const std = @import("std");
const Object = py.Object;
const Type = py.Type;
const Tuple = py.Tuple;
const Dict = py.Dict;
const Atom = @import("../atom.zig").Atom;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const Member = member.Member;
const InstanceMember = @import("instance.zig").InstanceMember;

const package_name = @import("../api.zig").package_name;

pub const TypedDict = extern struct {
    const Self = @This();
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;

    base: Dict,
    validate_context: ?*Tuple = null, // tuple[Optional[MemberBase], Optional[MemberBase], Atom]

    pub usingnamespace py.ObjectProtocol(Self);

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *const Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    // --------------------------------------------------------------------------
    // Methods
    // --------------------------------------------------------------------------
    pub fn setdefault(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n < 1 or n > 2) {
            return py.typeErrorObject(null, "setdefault expects 1 or 2 arguments", .{});
        }
        const key = args[0];
        if (self.base.get(key)) |value| {
            return value.newref();
        }
        const default = if (n == 2) args[1] else py.None();
        if (self.assign_subscript(key, default) < 0) {
            return null;
        }
        return self.base.get(key);
    }

    pub fn update(self: *Self, args: *Tuple, kwargs: ?*Dict) ?*Object {
        _ = self;
        _ = args;
        _ = kwargs;

        // args.unpack("update", .{&item});
        // TODO: Implement
        return py.returnNone();
    }

    pub fn assign_subscript(self: *Self, key: *Object, value: ?*Object) c_int {
        if (value) |item| {
            const newkey = self.validateKey(item) catch return -1;
            defer newkey.decref();
            const newvalue = self.validateValue(item) catch return -1;
            defer newvalue.decref();
            return py.c.PyDict_Type.tp_as_mapping.*.mp_ass_subscript.?(@ptrCast(self), @ptrCast(newkey), @ptrCast(newvalue));
        }
        return py.c.PyDict_Type.tp_as_mapping.*.mp_ass_subscript.?(@ptrCast(self), @ptrCast(key), @ptrCast(value));
    }

    // --------------------------------------------------------------------------
    // Internal api
    // --------------------------------------------------------------------------
    pub fn newNoContext(items: *Object) !*TypedDict {
        return @ptrCast(try TypeObject.?.callArgs(.{items}));
    }

    pub fn newWithContext(items: *Object, key_member: *MemberBase, value_member: *MemberBase, atom: *Atom) !*TypedDict {
        if (key_member.isNone() and value_member.isNone()) {
            try py.typeError("Cannot create TypedDict with no validators. Use a normal dict", .{});
        }

        if (!Dict.check(items)) {
            if (!key_member.isNone()) {
                try key_member.validateFail(atom, items, "dict");
            } else {
                try value_member.validateFail(atom, items, "dict");
            }
            unreachable;
        }
        const self: *Self = @ptrCast(try TypeObject.?.callArgs(.{}));
        errdefer self.decref();
        self.validate_context = try Tuple.packNewrefs(.{ key_member, value_member, atom });

        var pos: isize = 0;
        var dict: *Dict = @ptrCast(items);
        if (!key_member.isNone() and  !value_member.isNone()) {
            while (dict.next(&pos)) |entry| {
                const key = try key_member.validate(atom, py.None(), entry.key);
                defer key.decref();
                const value = try value_member.validate(atom, py.None(), entry.value);
                defer value.decref();
                try self.base.set(key, value);
            }
        } else if (!key_member.isNone()) {
            while (dict.next(&pos)) |entry| {
                const key = try key_member.validate(atom, py.None(), entry.key);
                defer key.decref();
                try self.base.set(key, entry.value);
            }
        } else if (!value_member.isNone()) {
            while (dict.next(&pos)) |entry| {
                const value = try value_member.validate(atom, py.None(), entry.value);
                defer value.decref();
                try self.base.set(entry.key, value);
            }
        } else {
            unreachable;
        }

        return @ptrCast(self);
    }

    pub fn hasSameContext(self: *Self, key_member: *Object, value_member: *Object, atom: *Atom) bool {
        if (self.validate_context) |tuple| {
            return (tuple.getUnsafe(0).? == key_member and tuple.getUnsafe(1).? == value_member and @as(*Atom, @ptrCast(tuple.getUnsafe(2).?)) == atom);
        }
        return false;
    }

    pub inline fn validateKey(self: *Self, key: *Object) py.Error!*Object {
        if (self.validate_context) |tuple| {
            const key_member: *MemberBase = @ptrCast(tuple.getUnsafe(0).?);
            if (!key_member.isNone()) {
                const atom: *Atom = @ptrCast(tuple.getUnsafe(2).?);
                return try key_member.validate(atom, py.None(), key);
            }
        }
        return key.newref();
    }

    pub inline fn validateValue(self: *Self, value: *Object) py.Error!*Object {
        if (self.validate_context) |tuple| {
            const value_member: *MemberBase = @ptrCast(tuple.getUnsafe(1).?);
            if (!value_member.isNone()) {
                const atom: *Atom = @ptrCast(tuple.getUnsafe(2).?);
                return try value_member.validate(atom, py.None(), value);
            }
        }
        return value.newref();
    }

    // --------------------------------------------------------------------------
    // Type definition
    // --------------------------------------------------------------------------
    pub fn dealloc(self: *Self) void {
        self.gcUntrack();
        py.clear(&self.validate_context);
        py.c.PyDict_Type.tp_dealloc.?(@ptrCast(self));
    }

    pub fn clear(self: *Self) c_int {
        py.clear(&self.validate_context);
        return py.c.PyDict_Type.tp_clear.?(@ptrCast(self));
    }

    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        const r = py.visit(self.validate_context, visit, arg);
        if (r != 0)
            return r;
        return py.c.PyDict_Type.tp_traverse.?(@ptrCast(self), visit, arg);
    }

    const methods = [_]py.MethodDef{
        .{ .ml_name = "setdefault", .ml_meth = @constCast(@ptrCast(&setdefault)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "If key is in the dictionary, return its value. If not, insert key with a value of default and return default. default defaults to None." },
        .{ .ml_name = "update", .ml_meth = @constCast(@ptrCast(&update)), .ml_flags = py.c.METH_VARARGS | py.c.METH_KEYWORDS, .ml_doc = "Update the dictionary with the key/value pairs from other, overwriting existing keys. Return None." },
        .{}, // sentinel
    };

    const type_slots = [_]py.TypeSlot{
        .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
        .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
        .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
        .{ .slot = py.c.Py_mp_ass_subscript, .pfunc = @constCast(@ptrCast(&assign_subscript)) },
        .{ .slot = py.c.Py_tp_methods, .pfunc = @constCast(@ptrCast(&methods)) },
        .{}, // sentinel
    };

    pub var TypeSpec = py.TypeSpec{
        .name = package_name ++ ".TypedDict",
        .basicsize = @sizeOf(Self),
        .flags = (py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_HAVE_GC),
        .slots = @constCast(@ptrCast(&type_slots)),
    };

    pub fn initType() !void {
        if (TypeObject != null) return;
        TypeObject = try Type.fromSpecWithBases(&TypeSpec, @ptrCast(&py.c.PyDict_Type));
    }

    pub fn deinitType() void {
        py.clear(&TypeObject);
    }
};

pub const DictMember = Member("Dict", 1, struct {

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

            self.validate_context = @ptrCast(try Tuple.packNewrefs(.{ key_member, value_member }));
            if (!key_member.isNone()) {
                try self.bindValidatorMember(@ptrCast(key_member), member.key_str.?);
            }
            if (!value_member.isNone()) {
                try self.bindValidatorMember(@ptrCast(value_member), member.value_str.?);
            }
        }
    }

    pub fn defaultStatic(self: *MemberBase, atom: *Atom) !*Object {
        if (self.default_context) |default_value| {
            if (self.validate_context) |context| {
                // Do it here or it just gets copied again by the coerce function later
                const tuple: *Tuple = @ptrCast(context);
                const k = tuple.getUnsafe(0).?;
                const v = tuple.getUnsafe(1).?;
                return @ptrCast(try TypedDict.newWithContext(default_value, @ptrCast(k), @ptrCast(v), atom));
            }
            return @ptrCast(try Dict.copy(@ptrCast(default_value)));
        }
        try py.systemError("default context missing", .{});
        unreachable;
    }

    // This cannot be inlined
    pub fn coerce(self: *const MemberBase, atom: *Atom, _: *Object, value: *Object) py.Error!*Object {
        if (self.validate_context) |context| {
            const tuple: *Tuple = @ptrCast(context);
            const k = tuple.getUnsafe(0).?;
            const v = tuple.getUnsafe(1).?;
            if (TypedDict.check(value)) {
                const typed_dict: *TypedDict = @ptrCast(value);
                if (typed_dict.hasSameContext(k, v, atom)) {
                    return value.newref();
                }
            }
            return @ptrCast(try TypedDict.newWithContext(value, @ptrCast(k), @ptrCast(v), atom));
        } else if (Dict.check(value)) {
            return value.newref(); // untyped dicts do not need coereced
        }
        try self.validateFail(atom, value, "dict");
        unreachable;
    }

});

pub const all_members = .{
    DictMember,
};

pub fn initModule(mod: *py.Module) !void {
    try TypedDict.initType();
    errdefer TypedDict.deinitType();
    try mod.addObjectRef("TypedDict", @ptrCast(TypedDict.TypeObject.?));

    inline for (all_members) |T| {
        try T.initType();
        errdefer T.deinitType();
        try mod.addObjectRef(T.TypeName, @ptrCast(T.TypeObject.?));
    }
}

pub fn deinitModule(mod: *py.Module) void {
    _ = mod;
    TypedDict.deinitType();
    inline for (all_members) |T| {
        T.deinitType();
    }
}
