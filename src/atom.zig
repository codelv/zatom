const py = @import("py.zig");
const std = @import("std");
const Type = py.Type;
const Object = py.Object;
const Str = py.Str;
const Tuple = py.Tuple;
const Dict = py.Dict;

const AtomMeta = @import("atom_meta.zig").AtomMeta;
const ObserverPool = @import("observer_pool.zig").ObserverPool;
const package_name = @import("api.zig").package_name;

// If slot count is over this it will use a data pointer
const MAX_INLINE_SLOT_COUNT = 64;

var frozen_str: ?*Str = null;

// These are generated a compt
pub var atom_types = [_]?*Type{null} ** MAX_INLINE_SLOT_COUNT;

pub const AtomInfo = packed struct { slot_count: u16 = 0, notifications_disabled: bool = false, has_guards: bool = false, has_atomref: bool = false, has_observers: bool = false, is_frozen: bool = false, _reserved: u11 = 0 };

// Base Atom class
pub const AtomBase = extern struct {
    const Self = @This();
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;
    pub const BaseType = Object.BaseType;
    base: BaseType,
    pool: ?*ObserverPool = null,
    info: AtomInfo,
    slots: [1]?*Object,

    pub usingnamespace py.ObjectProtocol(Self);

    pub fn new(cls: *Type, args: *Tuple, kwargs: ?*Dict) ?*Self {
        if (!AtomMeta.check(@ptrCast(cls))) {
            return @ptrCast(py.typeError("atom meta"));
        }
        const meta: *AtomMeta = @ptrCast(cls);
        const self: *Self = @ptrCast(cls.genericNew(args, kwargs) catch return null);
        self.info.slot_count = meta.slot_count;
        return self;
    }

    pub fn init(self: *Self, args: *Tuple, kwargs: ?*Dict) c_int {
        if (args.sizeUnsafe() > 0) {
            _ = py.typeError("__init__() takes no positional arguments");
            return -1;
        }
        if (kwargs) |kw| {
            var pos: isize = 0;
            const obj: *Object = @ptrCast(self);
            obj.incref();
            defer obj.decref();
            while (kw.next(&pos)) |entry| {
                obj.setAttr(@ptrCast(entry.key), entry.value) catch return -1;
            }
        }
        return 0;
    }

    // Get a pointer to slot at the given index
    // This intentionally disables safety checking to write into the
    // inlined slots
    pub fn slotPtr(self: *Self, i: u16) ?*?*Object {
        if (i < self.info.slot_count) {
            @setRuntimeSafety(false);
            return &self.slots[i];
        }
        return null;
    }

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    pub fn dealloc(self: *Self) void {
        const selfptr: *Object = @ptrCast(self);
        selfptr.gcUntrack();
        _ = self.clear();
        if (self.pool) |pool| {
            pool.deinit();
            self.pool = null;
        }
        selfptr.typeref().impl.tp_free.?(selfptr);
    }

    pub fn clear(self: *Self) c_int {
        py.clear(&self.slots[0]);
        if (self.pool) |pool| {
            pool.clear() catch {
                _ = py.memoryError();
                return -1;
            };
        }
        return 0;
    }

    // Check if object is an atom_meta
    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        if (self.pool) |pool| {
            const r = pool.traverse(visit, arg);
            if (r != 0)
                return r;
        }
        return py.visit(self.slots[0], visit, arg);
    }

    const methods = [_]py.MethodDef{
        //         .{
        //             .ml_name="init_subclass",
        //             .ml_meth=@constCast(@ptrCast(&init_subclass)),
        //             .ml_flags=py.c.METH_CLASS | py.c.METH_NOARGS,
        //             .ml_doc="Initialize the atom_members for the subclass"
        //
        //         },
        .{}, // sentinel
    };
    const type_slots = [_]py.TypeSlot{
        //.{.slot=py.c.Py_tp_new, .pfunc=@constCast(@ptrCast(&new))},
        .{ .slot = py.c.Py_tp_init, .pfunc = @constCast(@ptrCast(&init)) },
        .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
        .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
        .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
        .{ .slot = py.c.Py_tp_methods, .pfunc = @constCast(@ptrCast(&methods)) },
        .{}, // sentinel
    };
    pub var TypeSpec = py.TypeSpec{
        .name = package_name ++ ".AtomBase",
        .basicsize = @sizeOf(AtomBase),
        .flags = (py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_BASETYPE | py.c.Py_TPFLAGS_HAVE_GC),
        .slots = @constCast(@ptrCast(&type_slots)),
    };

    pub fn initType() !void {
        if (TypeObject != null) return;
        if (AtomMeta.TypeObject == null) {
            _ = py.systemError("AtomMeta type not ready");
            return error.PyError;
        }
        // Hack to bypass the metaclass check
        AtomMeta.disableNew();
        defer AtomMeta.enableNew();
        TypeObject = try Type.fromMetaclass(AtomMeta.TypeObject, null, &TypeSpec, null);
    }

    pub fn deinitType() void {
        py.clear(@ptrCast(&TypeObject));
    }
};

comptime {
    const size = @sizeOf(AtomBase);
    if (size != 40) {
        @compileLog("Expected 40 bytes got {}", .{size});
    }
}
// Generate a type that extends the AtomBase with inlined slots
pub fn Atom(comptime slot_count: u16) type {
    if (slot_count < 2) {
        @compileError("Cannot create an atom with < 2 slots. Use the AtomBase instead");
    }
    return struct {
        // Reference to the type. This is set in ready
        pub var TypeObject: ?*Type = null;
        pub const BaseType = AtomBase;
        const Self = @This();

        base: BaseType,
        slots: [slot_count]?*Object,

        // Import the object protocol
        pub usingnamespace py.ObjectProtocol(@This());

        // Type check the given object. This assumes the module was initialized
        pub fn check(obj: *Object) bool {
            return obj.typeCheck(TypeObject.?);
        }

        pub fn dealloc(self: *Self) void {
            self.gcUntrack();
            _ = self.clear();
            self.typeref().impl.tp_free.?(@ptrCast(self));
        }

        pub fn clear(self: *Self) c_int {
            const r = self.base.clear();
            if (r != 0)
                return r;
            inline for (0..self.slots.len) |i| {
                py.clear(&self.slots[i]);
            }
            return 0;
        }

        pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
            const r = self.base.traverse(visit, arg);
            if (r != 0)
                return r;
            return py.visitAll(self.slots, visit, arg);
        }

        const type_slots = [_]py.TypeSlot{
            .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
            .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
            .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
            .{}, // sentinel
        };
        pub var TypeSpec = py.TypeSpec{
            .name = package_name ++ std.fmt.comptimePrint(".Atom{}", .{slot_count}),
            .basicsize = @sizeOf(Self),
            .flags = (py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_BASETYPE | py.c.Py_TPFLAGS_HAVE_GC),
            .slots = @constCast(@ptrCast(&type_slots)),
        };

        pub fn initType() !void {
            if (TypeObject != null) return;
            // Hack to bypass the metaclass check
            AtomMeta.disableNew();
            defer AtomMeta.enableNew();
            TypeObject = try Type.fromSpecWithBases(&TypeSpec, @ptrCast(AtomBase.TypeObject));
        }

        pub fn deinitType() void {
            py.clear(@ptrCast(&TypeObject));
        }
    };
}

pub fn initModule(mod: *py.Module) !void {
    frozen_str = try py.Str.internFromString("--frozen");
    errdefer py.clear(@ptrCast(&frozen_str));
    try AtomBase.initType();
    errdefer AtomBase.deinitType();

    // Initialize types with fixed slots
    atom_types[0] = AtomBase.TypeObject.?.newref();
    atom_types[1] = AtomBase.TypeObject.?.newref();
    inline for (2..atom_types.len) |i| {
        const T = Atom(i);
        try T.initType();
        errdefer T.deinitType();
        atom_types[i] = T.TypeObject.?.newref();
    }

    // The metaclass generates subclasses
    try mod.addObjectRef("Atom", @ptrCast(AtomBase.TypeObject.?));
}

pub fn deinitModule(mod: *py.Module) void {
    py.clear(@ptrCast(&frozen_str));

    py.clear(@ptrCast(&atom_types[0]));
    py.clear(@ptrCast(&atom_types[1]));
    inline for (2..atom_types.len) |i| {
        // Clear the type slot
        py.clear(@ptrCast(&atom_types[i]));
        Atom(i).deinitType();
    }
    AtomBase.deinitType();
    _ = mod; // TODO: Remove dead type
}
