const py = @import("py.zig");
const std = @import("std");
const Type = py.Type;
const Object = py.Object;
const Str = py.Str;
const Int = py.Int;
const Tuple = py.Tuple;
const Dict = py.Dict;

const AtomMeta = @import("atom_meta.zig").AtomMeta;
const MemberBase = @import("member.zig").MemberBase;
const ObserverPool = @import("observer_pool.zig").ObserverPool;
const ChangeType = @import("observer_pool.zig").ChangeType;
const package_name = @import("api.zig").package_name;

// If slot count is over this it will use a data pointer
const MAX_INLINE_SLOT_COUNT = 64;

var frozen_str: ?*Str = null;

// These are generated a compt
pub var atom_types = [_]?*Type{null} ** MAX_INLINE_SLOT_COUNT;

// zig fmt: off
pub const AtomInfo = packed struct {
    pool_index: u32 = 0,
    slot_count: u16 = 0,
    notifications_disabled: bool = false,
    has_guards: bool = false,
    has_atomref: bool = false,
    has_observers: bool = false,
    is_frozen: bool = false,
    _reserved: u11 = 0
};
// zig fmt: on
comptime {
    if (@bitSizeOf(AtomInfo) != 64) {
        @compileError(std.fmt.comptimePrint("AtomInfo should be 64 bits: got {}", .{@bitSizeOf(AtomInfo)}));
    }
}

// Base Atom class
pub const AtomBase = extern struct {
    const Self = @This();
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;
    base: Object,
    info: AtomInfo,
    slots: [1]?*Object,

    pub usingnamespace py.ObjectProtocol(Self);

    pub fn new(cls: *Type, args: *Tuple, kwargs: ?*Dict) ?*Self {
        if (!AtomMeta.check(@ptrCast(cls))) {
            return @ptrCast(py.typeError("atom meta", .{}));
        }
        const self: *Self = @ptrCast(cls.genericNew(args, kwargs) catch return null);
        const meta: *AtomMeta = @ptrCast(cls);
        self.info.slot_count = meta.slot_count;
        return self;
    }

    pub fn init(self: *Self, args: *Tuple, kwargs: ?*Dict) c_int {
        if (args.sizeUnchecked() > 0) {
            _ = py.typeError("__init__() takes no positional arguments", .{});
            return -1;
        }
        if (kwargs) |kw| {
            var pos: isize = 0;
            while (kw.next(&pos)) |entry| {
                self.setAttr(@ptrCast(entry.key), entry.value) catch return -1;
            }
        }
        return 0;
    }

    // Get a pointer to slot address at the given index
    pub fn slotPtr(self: *Self, i: u32) ?*?*Object {
        if (i < self.info.slot_count) {
            // This intentionally disables safety checking because it
            // intentionally writes into the inlined slots in the Atom(n) subclass
            // as long as the slot_count was properly set by the metaclass this is ok.
            @setRuntimeSafety(false);
            return &self.slots[i];
        }
        return null;
    }

    // Get a pointer to the ObserverPool from the manager on the type.
    pub fn dynamicObserverPool(self: *Self) ?*ObserverPool {
        if (self.info.has_observers) {
            const meta: *AtomMeta = @ptrCast(self.typeref());
            return meta.pool_manager.?.get(self.info.pool_index);
        }
        return null;
    }

    // Get a pointer to the static observer pool
    pub fn staticObserverPool(self: *Self) ?*ObserverPool {
        const meta: *AtomMeta = @ptrCast(self.typeref());
        return meta.static_observers;
    }

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    // --------------------------------------------------------------------------
    // Internal observer api
    // --------------------------------------------------------------------------
    // It should be a string, but it can raise an error if topic is not hashable
    pub fn hasDynamicObservers(self: *Self, topic: *Str) !bool {
        if (self.dynamicObserverPool()) |pool| {
            return try pool.hasTopic(topic);
        }
        return false;
    }

    pub fn hasDynamicObserver(self: *Self, topic: *Str, observer: *Object) !bool {
        if (self.dynamicObserverPool()) |pool| {
            return try pool.hasObserver(topic, observer, @intFromEnum(ChangeType.any));
        }
        return false;
    }

    pub fn hasStaticObservers(self: *Self, topic: *Str) !bool {
        if (self.staticObserverPool()) |pool| {
            return try pool.hasTopic(topic);
        }
        return false;
    }

    pub fn hasAnyObservers(self: *Self, topic: *Str) !bool {
        return (try self.hasStaticObservers(topic) or
            try self.hasDynamicObservers(topic));
    }

    // Assumes caller has checked observer is callable or str
    pub fn addDynamicObserver(self: *Self, topic: *Str, observer: *Object, change_types: u8) py.Error!void {
        if (!self.info.has_observers) {
            const meta: *AtomMeta = @ptrCast(self.typeref());
            std.debug.assert(meta.typeCheckSelf());
            self.info.pool_index = try meta.pool_manager.?.acquire(py.allocator);
            self.info.has_observers = true;
        }
        const pool = self.dynamicObserverPool().?;
        pool.addObserver(py.allocator, topic, observer, change_types) catch |err| {
            switch (err) {
                error.PyError => {},
                error.OutOfMemory => {
                    _ = py.memoryError();
                },
            }
            return error.PyError;
        };
    }

    pub fn removeDynamicObserver(self: *Self, topic: *Str, observer: *Object) !void {
        if (self.dynamicObserverPool()) |pool| {
            try pool.removeObserver(py.allocator, topic, observer);
        }
    }

    pub fn removeTopic(self: *Self, topic: *Str) !void {
        if (self.dynamicObserverPool()) |pool| {
            try pool.removeTopic(py.allocator, topic);
        }
    }

    pub fn clearDynamicObservers(self: *Self) !void {
        if (self.dynamicObserverPool()) |pool| {
            try pool.clear(py.allocator);
        }
    }

    pub fn notifyInternal(self: *Self, topic: *Str, args: *Tuple, kwargs: ?*Dict, change_types: u8) !void {
        if (self.staticObserverPool()) |pool| {
            try pool.notify(py.allocator, topic, args, kwargs, change_types);
        }
        if (self.dynamicObserverPool()) |pool| {
            try pool.notify(py.allocator, topic, args, kwargs, change_types);
        }
    }

    // --------------------------------------------------------------------------
    // Methods
    // --------------------------------------------------------------------------
    pub fn has_observers(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n == 0) {
            if (self.dynamicObserverPool()) |pool| {
                return py.returnBool(pool.map.size > 0);
            }
            return py.returnFalse();
        }
        if (n == 1 and Str.check(args[0])) {
            return py.returnBool(self.hasDynamicObservers(@ptrCast(args[0])) catch return null);
        }
        return py.typeError("Invalid arguments. Signature is has_observers(topic: Optional[str] = None)", .{});
    }

    pub fn has_observer(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n != 2 or !Str.check(args[0]) or !args[1].isCallable()) {
            return py.typeError("Invalid arguments. Signature is has_observer(topic: str, observer: Callable)", .{});
        }
        return py.returnBool(self.hasDynamicObserver(@ptrCast(args[0]), args[1]) catch return null);
    }

    pub fn observe(self: *Self, args: [*]*Object, n: isize) ?*Object {
        const msg = "Invalid arguments. Signature is observe(topics: str | Iterable[str], observer: Callable, change_types: int=0xff)";
        if (n < 2 or n > 3 or !args[1].isCallable()) {
            return py.typeError(msg, .{});
        }
        const topic = args[0];
        const callback = args[1];
        const change_types: u8 = blk: {
            if (n == 3) {
                const v = args[2];
                if (!Int.check(v)) {
                    return py.typeError(msg, .{});
                }
                break :blk Int.as(@ptrCast(v), u8) catch return null;
            }
            break :blk @intFromEnum(ChangeType.any);
        };
        if (Str.check(topic)) {
            self.addDynamicObserver(@ptrCast(topic), callback, change_types) catch return null;
        } else {
            const iter = topic.iter() catch return null;
            while (iter.next() catch return null) |item| {
                defer item.decref();
                if (!Str.check(item)) {
                    return py.typeError(msg, .{});
                }
                self.addDynamicObserver(@ptrCast(item), callback, change_types) catch return null;
            }
        }
        return py.returnNone();
    }

    pub fn unobserve(self: *Self, args: [*]*Object, n: isize) ?*Object {
        switch (n) {
            0 => {
                self.clearDynamicObservers() catch return null;
                return py.returnNone();
            },
            1 => if (Str.check(args[0])) {
                self.removeTopic(@ptrCast(args[0])) catch return null;
                return py.returnNone();
            },
            2 => if (Str.check(args[0])) {
                self.removeDynamicObserver(@ptrCast(args[0]), args[1]) catch return null;
                return py.returnNone();
            },
            else => {},
        }
        return py.typeError("Invalid arguments. Signature is unobserve(topic: Optional[str]=None, observer: Optional[Callable]=None)", .{});
    }

    pub fn notify(self: *Self, args: *Tuple, kwargs: ?*Dict) ?*Object {
        const n = args.size() catch return null;
        if (n < 1 or !Str.check(args.getUnsafe(0).?)) {
            return py.typeError("Invalid arguments. Signature is notify(topic: str, *args, **kwargs)", .{});
        }
        const topic: *Str = @ptrCast(args.getUnsafe(0).?);
        const new_args = args.slice(1, n) catch return null;
        self.notifyInternal(topic, new_args, kwargs, @intFromEnum(ChangeType.any)) catch return null;
        return py.returnNone();
    }

    pub fn get_member(cls: *Object, name: *Object) ?*Object {
        if (!AtomMeta.check(@ptrCast(cls))) {
            // @branchHint(.cold);
            return py.typeError("Atom must be defined with AtomMeta as a metatype", .{});
        }
        const meta: *AtomMeta = @ptrCast(cls);
        return meta.get_member(name);
    }

    pub fn get_members(cls: *Object) ?*Object {
        if (!AtomMeta.check(@ptrCast(cls))) {
            // @branchHint(.cold);
            return py.typeError("Atom must be defined with AtomMeta as a metatype", .{});
        }
        const meta: *AtomMeta = @ptrCast(cls);
        return meta.get_atom_members();
    }

    pub fn sizeof(self: *Self) ?*Object {
        var size: usize = @sizeOf(Self);
        if (self.dynamicObserverPool()) |pool| {
            size += pool.sizeof();
        }
        return @ptrCast(Int.newUnchecked(size));
    }

    // --------------------------------------------------------------------------
    // Type def
    // --------------------------------------------------------------------------
    pub fn dealloc(self: *Self) void {
        self.gcUntrack();
        _ = self.clear();
        if (self.dynamicObserverPool() != null) {
            const meta: *AtomMeta = @ptrCast(self.typeref());
            meta.pool_manager.?.release(py.allocator, self.info.pool_index) catch {};
        }
        self.typeref().free(@ptrCast(self));
    }

    pub fn clear(self: *Self) c_int {
        if (self.dynamicObserverPool()) |pool| {
            pool.clear(py.allocator) catch return -1;
        }

        // Since some members fill slots with other data, the slot might not be a *Object
        // so instead of using py.clear we delegate clearing to the members themselves.
        const meta: *AtomMeta = @ptrCast(self.typeref());
        std.debug.assert(meta.typeCheckSelf());
        if (meta.gc_members) |members| {
            for (members.items) |member| {
                @setRuntimeSafety(false);
                py.clear(&self.slots[member.info.index]);
            }
        }
        return 0;
    }

    // Check if object is an atom_meta
    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        if (self.dynamicObserverPool()) |pool| {
            const r = pool.traverse(visit, arg);
            if (r != 0)
                return r;
        }
        const meta: *AtomMeta = @ptrCast(self.typeref());
        std.debug.assert(meta.typeCheckSelf());
        if (meta.gc_members) |members| {
            for (members.items) |member| {
                @setRuntimeSafety(false);
                const r = py.visit(self.slots[member.info.index], visit, arg);
                if (r != 0)
                    return r;
            }
        }
        return 0;
    }

    const methods = [_]py.MethodDef{
        .{ .ml_name = "get_member", .ml_meth = @constCast(@ptrCast(&get_member)), .ml_flags = py.c.METH_CLASS | py.c.METH_O, .ml_doc = "Get the atom member with the given name" },
        .{ .ml_name = "members", .ml_meth = @constCast(@ptrCast(&get_members)), .ml_flags = py.c.METH_CLASS | py.c.METH_NOARGS, .ml_doc = "Get atom members" },
        .{ .ml_name = "observe", .ml_meth = @constCast(@ptrCast(&observe)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Register an observer callback to observe changes on the given topic(s)" },
        .{ .ml_name = "unobserve", .ml_meth = @constCast(@ptrCast(&unobserve)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Unregister an observer callback for the given topic(s)." },
        .{ .ml_name = "has_observers", .ml_meth = @constCast(@ptrCast(&has_observers)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Get whether the atom has observers for a given topic." },
        .{ .ml_name = "has_observer", .ml_meth = @constCast(@ptrCast(&has_observer)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Get whether the atom has the given observer for a given topic." },
        .{ .ml_name = "notify", .ml_meth = @constCast(@ptrCast(&notify)), .ml_flags = py.c.METH_VARARGS | py.c.METH_KEYWORDS, .ml_doc = "Call the registered observers for a given topic with positional and keyword arguments." },
        .{ .ml_name = "__sizeof__", .ml_meth = @constCast(@ptrCast(&sizeof)), .ml_flags = py.c.METH_NOARGS, .ml_doc = "Get size of object in memory in bytes" },
        .{}, // sentinel
    };
    const type_slots = [_]py.TypeSlot{
        .{ .slot = py.c.Py_tp_new, .pfunc = @constCast(@ptrCast(&new)) },
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
            _ = py.systemError("AtomMeta type not ready", .{});
            return error.PyError;
        }
        // Hack to bypass the metaclass check
        AtomMeta.disableNew();
        defer AtomMeta.enableNew();
        TypeObject = try Type.fromMetaclass(AtomMeta.TypeObject, null, &TypeSpec, null);
    }

    pub fn deinitType() void {
        py.clear(&TypeObject);
    }
};

comptime {
    const size = @sizeOf(AtomBase);
    if (size != 32) {
        @compileLog("Expected 32 bytes got {}", .{size});
    }
}
// Generate a type that extends the AtomBase with inlined slots
pub fn Atom(comptime slot_count: u16) type {
    if (slot_count < 2) {
        @compileError("Cannot create an AtomBase subclass with < 2 slots. Use the AtomBase instead");
    }
    return extern struct {
        // Reference to the type. This is set in ready
        pub var TypeObject: ?*Type = null;
        const Self = @This();

        base: AtomBase,
        slots: [slot_count]?*Object,

        comptime {
            // Check that alignment of base and this class's slots are correct
            // Otherwise it will start smashing stuff..
            const slot_size = @sizeOf(?*Object);
            if (@offsetOf(AtomBase, "slots") + slot_size != @offsetOf(Self, "slots")) {
                @compileError(std.fmt.comptimePrint("Slots of AtomBase and {} are not contiguous in memory", .{Self}));
            }
        }

        // Import the object protocol
        pub usingnamespace py.ObjectProtocol(@This());

        // Type check the given object. This assumes the module was initialized
        pub fn check(obj: *Object) bool {
            return obj.typeCheck(TypeObject.?);
        }

        // --------------------------------------------------------------------------
        // Type definition
        // --------------------------------------------------------------------------
        const type_slots = [_]py.TypeSlot{
            .{}, // sentinel
        };
        pub var TypeSpec = py.TypeSpec{
            .name = package_name ++ std.fmt.comptimePrint(".Atom{}", .{slot_count}),
            .basicsize = @sizeOf(Self),
            // All slots are traversed by the base class so this doesn't need the GC flag
            .flags = (py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_BASETYPE),
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
            py.clear(&TypeObject);
        }
    };
}

pub fn initModule(mod: *py.Module) !void {
    frozen_str = try py.Str.internFromString("--frozen");
    errdefer py.clear(&frozen_str);
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
    py.clear(&frozen_str);

    py.clear(&atom_types[0]);
    py.clear(&atom_types[1]);
    inline for (2..atom_types.len) |i| {
        // Clear the type slot
        py.clear(&atom_types[i]);
        Atom(i).deinitType();
    }
    AtomBase.deinitType();
    _ = mod; // TODO: Remove dead type
}
