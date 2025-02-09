const py = @import("py.zig");
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
var atom_types = [_]?*Type{null} ** MAX_INLINE_SLOT_COUNT;

pub const AtomInfo = packed struct {
    slot_count: u16 = 0,
    notifications_disabled: bool = false,
    has_guards: bool = false,
    has_atomref: bool = false,
    has_observers: bool = false,
    is_frozen: bool = false,
    _reserved: u11 = 0
};

// Base Atom class
pub const AtomBase = extern struct {
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;
    pub const BaseType = Object.BaseType;
    base: BaseType,
    pool: ObserverPool,
    info: AtomInfo,

    pub fn new(type: *Type, args: ?*Tuple, kwargs: ?*Dict) ?*AtomBase {
        if (!AtomMeta.check(@ptrCast(type))) {
            return py.typeError("atom meta");
        }
    }

    pub fn init(self: *AtomBase, args: ?*Tuple, kwargs: ?*Dict) c_int {
        return 0;
    }

    pub fn init_subclass(cls: *Object) ?*Object {
        if (!AtomMeta.check(@ptrCast(cls))) {
            return py.typeError("atom meta");
        }
        return AtomMeta.init_subclass(@ptrCast(cls));
    }

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
        inline for(self.slots) |slot| {
            py.clear(@ptrCast(&slot));
        }
        return 0;
    }

    // Check if object is an atom_meta
    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        return py.visitAll(.{self.name}, visit, arg);
    }

    const methods = [_]py.MethodDef{
        .{
            .ml_name="init_subclass",
            .ml_meth=@constCast(@ptrCast(&init_subclass)),
            .ml_flags=py.c.METH_CLASS | py.c.METH_NOARGS,
            .ml_doc="Initialize the atom_members for the subclass"

        },
        .{} // sentinel
    };
    const slots = [_]py.TypeSlot{
        .{.slot=py.c.Py_tp_new, .pfunc=@constCast(@ptrCast(&new))},
        .{.slot=py.c.Py_tp_init, .pfunc=@constCast(@ptrCast(&init))},
        .{.slot=py.c.Py_tp_dealloc, .pfunc=@constCast(@ptrCast(&dealloc))},
        .{.slot=py.c.Py_tp_traverse, .pfunc=@constCast(@ptrCast(&traverse))},
        .{.slot=py.c.Py_tp_clear, .pfunc=@constCast(@ptrCast(&clear))},
        .{} // sentinel
    };
    pub var TypeSpec = py.TypeSpec{
        .name=package_name ++ ".AtomBase",
        .basicsize=@sizeOf(Atom),
        .flags=(py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_BASETYPE | py.c.Py_TPFLAGS_HAVE_GC),
        .slots=@constCast(@ptrCast(&slots)),
    };

    pub fn initType() !void {
        if (TypeObject != null) return;
        TypeObject = try Type.fromSpec(&TypeSpec);
    }

    pub fn deinitType() void {
        py.clear(@ptrCast(&TypeObject));
    }
};

// Generate a type that extends the AtomBase with inlined slots
pub fn Atom(comptime slot_count: u16) type {
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
            inline for(self.slots) |*slot| {
                py.clear(slot);
            }
            return 0;
        }

        pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
            return py.visitAll(self.slots, visit, arg);
        }

        const methods = [_]py.MethodDef{
            .{
                .ml_name="get_slot",
                .ml_meth=@constCast(@ptrCast(&get_slot)),
                .ml_flags=py.c.METH_O,
                .ml_doc="Get slot value directly"

            },
            .{} // sentinel
        };

        const slots = [_]py.TypeSlot{
            .{.slot=py.c.Py_tp_dealloc, .pfunc=@constCast(@ptrCast(&dealloc))},
            .{.slot=py.c.Py_tp_traverse, .pfunc=@constCast(@ptrCast(&traverse))},
            .{.slot=py.c.Py_tp_clear, .pfunc=@constCast(@ptrCast(&clear))},
            .{.slot=py.c.Py_tp_methods, .pfunc=@constCast(@ptrCast(&methods))},
            .{} // sentinel
        };
        pub var TypeSpec = py.TypeSpec{
            .name=package_name ++ ".Atom[]",
            .basicsize=@sizeOf(Atom),
            .flags=(py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_BASETYPE | py.c.Py_TPFLAGS_HAVE_GC),
            .slots=@constCast(@ptrCast(&slots)),
        };

        pub fn initType() !void {
            if (TypeObject != null) return;
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
    inline for(0..atom_types.len) |i| {
        const num_slots = i+1;
        const T = Atom(num_slots);
        try T.initType();
        errdefer T.deinitType();
        atom_types[i] = T.TypeObject.?.newref();
    }

    // The metaclass generates subclasses
    try mod.addObjectRef("Atom", @ptrCast(AtomBase.TypeObject.?));
}

pub fn deinitModule(mod: *py.Module) void {
    py.clear(@ptrCast(&frozen_str));
    inline for(0..atom_types.len) |i| {
        // Clear the type slot
        py.clear(@ptrCast(&atom_types[i]));
        Atom(num_slots).deinitType();
    }
    AtomBase.deinitType();
    _ = mod; // TODO: Remove dead type
}

