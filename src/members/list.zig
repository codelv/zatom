const py = @import("../api.zig").py;
const std = @import("std");
const Object = py.Object;
const Type = py.Type;
const Str = py.Str;
const Int = py.Int;
const List = py.List;
const Tuple = py.Tuple;
const Dict = py.Dict;
const Slice = py.Slice;
const AtomBase = @import("../atom.zig").AtomBase;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const Member = member.Member;
const InstanceMember = @import("instance.zig").InstanceMember;
const IntMember = @import("scalars.zig").IntMember;
const package_name = @import("../api.zig").package_name;

var context_str: ?*Str = null;

pub const TypedList = extern struct {
    const Self = @This();
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*py.Type = null;

    base: List,
    validate_context: ?*Tuple = null, // tuple[MemberBase, AtomBase]

    pub usingnamespace py.ObjectProtocol(Self);

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *const Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    // --------------------------------------------------------------------------
    // Methods
    // --------------------------------------------------------------------------
    pub fn append(self: *Self, item: *Object) ?*Object {
        const new = self.validateOne(item) catch return null;
        defer new.decref();
        self.base.append(new) catch return null;
        return py.returnNone();
    }

    pub fn insert(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n != 2 or !Int.checkIndex(args[0])) {
            return py.typeErrorObject(null, "invalid insert arguments", .{});
        }
        const pos = Int.as(@ptrCast(args[0]), isize) catch return null;
        const new = self.validateOne(args[1]) catch return null;
        defer new.decref();
        self.base.insert(pos, new) catch return null;
        return py.returnNone();
    }

    pub fn extend(self: *Self, items: *Object) ?*Object {
        const copy = self.validateMany(items) catch return null;
        defer copy.decref();
        self.base.extend(copy) catch return null;
        return py.returnNone();
    }

    pub fn assign_item(self: *Self, index: isize, value: ?*Object) c_int {
        if (value) |item| {
            const new = self.validateOne(item) catch return -1;
            defer new.decref();
            return py.c.PyList_Type.tp_as_sequence.*.sq_ass_item.?(@ptrCast(self), index, @ptrCast(new));
        }
        return py.c.PyList_Type.tp_as_sequence.*.sq_ass_item.?(@ptrCast(self), index, @ptrCast(value));
    }

    pub fn assign_subscript(self: *Self, key: *Object, value: ?*Object) c_int {
        if (value) |item| {
            if (Int.checkIndex(key)) {
                const new = self.validateOne(item) catch return -1;
                defer new.decref();
                return py.c.PyList_Type.tp_as_mapping.*.mp_ass_subscript.?(@ptrCast(self), @ptrCast(key), @ptrCast(new));
            } else if (Slice.check(key)) {
                const copy = self.validateMany(item) catch return -1;
                defer copy.decref();
                return py.c.PyList_Type.tp_as_mapping.*.mp_ass_subscript.?(@ptrCast(self), @ptrCast(key), @ptrCast(copy));
            }
        }
        return py.c.PyList_Type.tp_as_mapping.*.mp_ass_subscript.?(@ptrCast(self), @ptrCast(key), @ptrCast(value));
    }

    pub fn inplace_concat(self: *Self, item: *Object) ?*Object {
        const new = self.validateOne(item) catch return null;
        defer new.decref();
        return @ptrCast(py.c.PyList_Type.tp_as_sequence.*.sq_inplace_concat.?(@ptrCast(self), @ptrCast(new)));
    }

    // --------------------------------------------------------------------------
    // Internal api
    // --------------------------------------------------------------------------
    pub fn newNoContext(items: *Object) !*TypedList {
        return @ptrCast(try TypeObject.?.callArgs(.{items}));
    }

    pub fn newWithContext(items: *Object, validate_member: *MemberBase, atom: *AtomBase) !*TypedList {
        if (!List.check(items)) {
            try validate_member.validateFail(atom, items, "list");
            unreachable;

        }
        const list: *List = @ptrCast(items);
        const n = try list.size();
        const self: *TypedList = @ptrCast(try TypeObject.?.genericNew(null, null));
        errdefer self.decref();

        // See PyList_New...
        const byte_count = n * @sizeOf(*Object);
        if (py.allocator.rawAlloc(byte_count, @alignOf(*Object), 0)) |ptr| {
            @memset(ptr[0..byte_count], 0);
            self.base.impl.ob_item = @alignCast(@ptrCast(ptr));
            self.base.setObjectSize(@intCast(n));
            self.base.impl.allocated = @intCast(n);
        } else {
            try py.memoryError();
        }

        for(0..n) |i| {
            const item = list.getUnsafe(i).?;
            const value = try validate_member.validate(atom, py.None(), item);
            self.base.setUnsafe(i, value);
        }
        self.validate_context = try Tuple.packNewrefs(.{ validate_member, atom });

        return @ptrCast(self);
    }

    pub fn hasSameContext(self: *Self, validate_member: ?*Object, atom: *AtomBase) bool {
        if (self.validate_context) |tuple| {
            return (tuple.getUnsafe(0) == validate_member and @as(*AtomBase, @ptrCast(tuple.getUnsafe(1).?)) == atom);
        }
        return validate_member == null;
    }

    pub inline fn validateOne(self: *Self, item: *Object) py.Error!*Object {
        const tuple = self.validate_context orelse return item.newref();
        const mem: *MemberBase = @ptrCast(tuple.getUnsafe(0).?);
        const atom: *AtomBase = @ptrCast(tuple.getUnsafe(1).?);
        return try mem.validate(atom, py.None(), item);
    }

    pub inline fn validateMany(self: *Self, items: *Object) py.Error!*Object {
        const tuple = self.validate_context orelse return items.newref();
        const mem: *MemberBase = @ptrCast(tuple.getUnsafe(0).?);
        const atom: *AtomBase = @ptrCast(tuple.getUnsafe(1).?);
        if (!List.check(items)) {
            try mem.validateFail(atom, items, "list");
            unreachable;
        }
        const list: *List = @ptrCast(items);
        const n = try list.size();
        const copy = try List.new(n);
        errdefer copy.decref();
        for(0..n) |i| {
            const value = try mem.validate(atom, py.None(), list.getUnsafe(i).?);
            copy.setUnsafe(i, value);
        }
        return @ptrCast(copy);
    }

    // --------------------------------------------------------------------------
    // Type definition
    // --------------------------------------------------------------------------
    pub fn dealloc(self: *Self) void {
        self.gcUntrack();
        py.clear(&self.validate_context);
        py.c.PyList_Type.tp_dealloc.?(@ptrCast(self));
    }

    pub fn clear(self: *Self) c_int {
        py.clear(&self.validate_context);
        return py.c.PyList_Type.tp_clear.?(@ptrCast(self));
    }

    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        const r = py.visit(self.validate_context, visit, arg);
        if (r != 0)
            return r;
        return py.c.PyList_Type.tp_traverse.?(@ptrCast(self), visit, arg);
    }

    const methods = [_]py.MethodDef{
        .{ .ml_name = "append", .ml_meth = @constCast(@ptrCast(&append)), .ml_flags = py.c.METH_O, .ml_doc = "Append an item to the list." },
        .{ .ml_name = "insert", .ml_meth = @constCast(@ptrCast(&insert)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Insert an item into the list." },
        .{ .ml_name = "extend", .ml_meth = @constCast(@ptrCast(&extend)), .ml_flags = py.c.METH_O, .ml_doc = "Extend the list with items from an iterable." },
        .{}, // sentinel
    };

    const type_slots = [_]py.TypeSlot{
        //.{ .slot = py.c.Py_tp_new, .pfunc = @constCast(@ptrCast(&new)) },
        .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
        .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
        .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
        .{ .slot = py.c.Py_sq_ass_item, .pfunc = @constCast(@ptrCast(&assign_item)) },
        .{ .slot = py.c.Py_mp_ass_subscript, .pfunc = @constCast(@ptrCast(&assign_subscript)) },
        .{ .slot = py.c.Py_sq_inplace_concat, .pfunc = @constCast(@ptrCast(&inplace_concat)) },
        .{ .slot = py.c.Py_tp_methods, .pfunc = @constCast(@ptrCast(&methods)) },
        .{}, // sentinel
    };

    pub var TypeSpec = py.TypeSpec{
        .name = package_name ++ ".TypedList",
        .basicsize = @sizeOf(Self),
        .flags = (py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_HAVE_GC),
        .slots = @constCast(@ptrCast(&type_slots)),
    };

    pub fn initType() !void {
        if (TypeObject != null) return;
        TypeObject = try Type.fromSpecWithBases(&TypeSpec, @ptrCast(&py.c.PyList_Type));
    }

    pub fn deinitType() void {
        py.clear(&TypeObject);
    }
};

pub const ListMember = Member("List", 6, struct {

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

    pub fn defaultStatic(self: *MemberBase, atom: *AtomBase) !*Object {
        if (self.default_context) |default_value| {
            if (self.validate_context) |validate_member| {
                // Do it here or it just gets copied again by the coerce function later
                return @ptrCast(try TypedList.newWithContext(default_value, @ptrCast(validate_member), atom));
            }
            return @ptrCast(try List.copy(@ptrCast(default_value)));
        }
        try py.systemError("default context missing", .{});
        unreachable;
    }

    pub fn coerce(self: *MemberBase, atom: *AtomBase, _: *Object, value: *Object) py.Error!*Object {
        if (self.validate_context) |validate_member| {
            if (TypedList.check(value)) {
                const typed_list: *TypedList = @ptrCast(value);
                if (typed_list.hasSameContext(self.validate_context, atom)) {
                    return value.newref();
                }
            }
            return @ptrCast(try TypedList.newWithContext(value, @ptrCast(validate_member), atom));
        } else if (List.check(value)) {
            return value.newref(); // untyped lists do not need coereced
        }
        try self.validateFail(atom, value, "list");
        unreachable;
    }

});

pub const all_members = .{
    ListMember,
};

pub fn initModule(mod: *py.Module) !void {
    context_str = try Str.internFromString("context");
    errdefer py.clear(&context_str);

    inline for (all_members) |T| {
        try T.initType();
        errdefer T.deinitType();
        try mod.addObjectRef(T.TypeName, @ptrCast(T.TypeObject.?));
    }
    try TypedList.initType();
    errdefer TypedList.deinitType();
    try mod.addObjectRef("TypedList", @ptrCast(TypedList.TypeObject.?));
}

pub fn deinitModule(mod: *py.Module) void {
    _ = mod;
    inline for (all_members) |T| {
        T.deinitType();
    }
    py.clear(&context_str);
}
