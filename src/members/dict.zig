const py = @import("../api.zig").py;
const std = @import("std");
const Object = py.Object;
const Type = py.Type;
const Tuple = py.Tuple;
const Dict = py.Dict;
const AtomBase = @import("../atom.zig").AtomBase;
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
    validate_context: ?*Tuple = null, // tuple[Optional[MemberBase], Optional[MemberBase], AtomBase]
    key_validator: ?MemberBase.Validator = null, // TODO: Consider eliminating this
    value_validator: ?MemberBase.Validator = null, // TODO: Consider eliminating this

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
            self.validateKey(item) catch return -1;
            self.validateValue(item) catch return -1;
        }
        return py.c.PyDict_Type.tp_as_mapping.*.mp_ass_subscript.?(@ptrCast(self), @ptrCast(key), @ptrCast(value));
    }

    // --------------------------------------------------------------------------
    // Internal api
    // --------------------------------------------------------------------------
    pub fn newNoContext(items: *Object) !*TypedDict {
        return @ptrCast(try TypeObject.?.callArgs(.{items}));
    }

    pub fn newWithContext(items: *Object, key_member: *MemberBase, value_member: *MemberBase, atom: *AtomBase) !*TypedDict {
        if (key_member.isNone() and value_member.isNone()) {
            try py.typeError("Cannot create TypedDict with no validators. Use a normal dict", .{});
        }

        const key_validator = if (key_member.isNone()) null else try member.dynamicValidate(key_member);
        const value_validator = if (value_member.isNone()) null else try member.dynamicValidate(value_member);
        if (!Dict.check(items)) {
            if (!key_member.isNone()) {
                try key_member.validateFail(atom, items, "dict");
            } else {
                try value_member.validateFail(atom, items, "dict");
            }
            unreachable;
        }
        // Validate the items
        const dict: *Dict = @ptrCast(items);
        var pos: isize = 0;
        if (key_validator != null and value_validator != null) {
            while (dict.next(&pos)) |entry| {
                try key_validator.?(key_member, atom, py.None(), entry.key);
                try value_validator.?(value_member, atom, py.None(), entry.value);
            }
        } else if (key_validator) |validator| {
            while (dict.next(&pos)) |entry| {
                try validator(key_member, atom, py.None(), entry.key);
            }
        } else if (value_validator) |validator| {
            while (dict.next(&pos)) |entry| {
                try validator(value_member, atom, py.None(), entry.value);
            }
        }

        const context = try Tuple.packNewrefs(.{ key_member, value_member, atom });
        errdefer context.decref();
        const self = try newNoContext(items);
        self.key_validator = key_validator;
        self.value_validator = value_validator;
        self.validate_context = context;
        return @ptrCast(self);
    }

    pub fn hasSameContext(self: *Self, key_member: *Object, value_member: *Object, atom: *AtomBase) bool {
        if (self.validate_context) |tuple| {
            return (tuple.getUnsafe(0).? == key_member and tuple.getUnsafe(1).? == value_member and @as(*AtomBase, @ptrCast(tuple.getUnsafe(2).?)) == atom);
        }
        return false;
    }

    pub inline fn validateKey(self: *Self, key: *Object) !void {
        if (self.key_validator) |validator| {
            const tuple = self.validate_context.?;
            const key_member: *MemberBase = @ptrCast(tuple.getUnsafe(0).?);
            const atom: *AtomBase = @ptrCast(tuple.getUnsafe(2).?);
            try validator(key_member, atom, py.None(), key);
        }
    }

    pub inline fn validateValue(self: *Self, value: *Object) !void {
        if (self.value_validator) |validator| {
            const tuple = self.validate_context.?;
            const value_member: *MemberBase = @ptrCast(tuple.getUnsafe(1).?);
            const atom: *AtomBase = @ptrCast(tuple.getUnsafe(2).?);
            try validator(value_member, atom, py.None(), value);
        }
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

            self.validate_context = @ptrCast(try Tuple.packNewrefs(.{ key_member, value_member }));
            if (!key_member.isNone()) {
                try self.bindValidatorMember(@ptrCast(key_member), member.key_str.?);
            }
            if (!value_member.isNone()) {
                try self.bindValidatorMember(@ptrCast(value_member), member.value_str.?);
            }
        }
    }

    pub fn defaultStatic(self: *MemberBase, atom: *AtomBase) !*Object {
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

    pub fn coerce(self: *MemberBase, atom: *AtomBase, value: *Object) !*Object {
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

    pub inline fn validate(self: *MemberBase, atom: *AtomBase, _: *Object, new: *Object) py.Error!void {
        if (TypedDict.check(new)) {
            return; // Already validated by dict
        }
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
