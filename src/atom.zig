const py = @import("py");
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

const SlotType = enum {
    inlined,
    pointer,
};

// Base Atom class
pub const Atom = extern struct {
    const Self = @This();
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;
    pub const slot_type = SlotType.inlined;
    base: Object,
    info: AtomInfo,
    slots: switch (slot_type) {
        .inlined => [1]?*Object,
        .pointer => [*]?*Object,
    },

    pub usingnamespace py.ObjectProtocol(Self);

    pub fn new(cls: *Type, args: *Tuple, kwargs: ?*Dict) ?*Self {
        if (!AtomMeta.check(@ptrCast(cls))) {
            return py.typeErrorObject(null, "atom meta", .{});
        }
        const meta: *AtomMeta = @ptrCast(cls);
        const self: *Self = @ptrCast(cls.genericNew(args, kwargs) catch return null);
        self.info.slot_count = meta.info.slot_count;
        if (comptime slot_type == .pointer) {
            const byte_count = self.info.slot_count * @sizeOf(*Object);
            if (py.allocator.rawAlloc(byte_count, @alignOf(*Object), 0)) |ptr| {
                @memset(ptr[0..byte_count], 0);
                self.slots = @alignCast(@ptrCast(ptr));
            } else {
                defer self.decref();
                return py.memoryErrorObject(null);
            }
        }
        if (comptime @import("api.zig").debug_level.creates) {
            py.print("Atom.new({s})\n", .{self.typeName()}) catch {
                defer self.decref();
                return null;
            };
        }
        return self;
    }

    pub fn init(self: *Self, args: *Tuple, kwargs: ?*Dict) c_int {
        if (args.sizeUnchecked() > 0) {
            return py.typeErrorObject(-1, "__init__() takes no positional arguments", .{});
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
    pub inline fn slotPtr(self: *Self, member: *MemberBase) py.Error!*?*Object {
        if (member.info.storage_mode != .none) {
            // @branchHint(.likely);
            const i = member.info.index;
            if (i < self.info.slot_count) {
                // @branchHint(.likely);
                // Disable bounds checking
                @setRuntimeSafety(false);
                return &self.slots[i];
            }
        }
        try py.attributeError("Member '{s}' of '{s}' has no storage", .{ member.name.?.data(), self.typeName() });
        unreachable;
    }

    // Get a pointer to the ObserverPool from the manager on the type.
    pub inline fn dynamicObserverPool(self: Self) ?*ObserverPool {
        if (self.info.has_observers) {
            const meta: *AtomMeta = @ptrCast(self.typeref());
            return meta.pool_manager.?.get(self.info.pool_index);
        }
        return null;
    }

    // Get a pointer to the static observer pool
    pub inline fn staticObserverPool(self: Self) ?*ObserverPool {
        const meta: *AtomMeta = @ptrCast(self.typeref());
        return meta.static_observers;
    }

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *const Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    // --------------------------------------------------------------------------
    // Internal observer api
    // --------------------------------------------------------------------------
    // It should be a string, but it can raise an error if topic is not hashable
    pub fn hasDynamicObservers(self: *Self, topic: *Str, change_types: u8) !bool {
        if (self.dynamicObserverPool()) |pool| {
            return try pool.hasAnyObserver(topic, change_types);
        }
        return false;
    }

    pub fn hasDynamicObserver(self: *Self, topic: *Str, observer: *Object, change_types: u8) !bool {
        if (self.dynamicObserverPool()) |pool| {
            return try pool.hasObserver(topic, observer, change_types);
        }
        return false;
    }

    pub fn hasStaticObservers(self: *Self, topic: *Str, change_types: u8) !bool {
        if (self.staticObserverPool()) |pool| {
            return try pool.hasAnyObserver(topic, change_types);
        }
        return false;
    }

    pub fn hasAnyObservers(self: *Self, topic: *Str, change_type: ChangeType) !bool {
        return (try self.hasStaticObservers(topic, @intFromEnum(change_type)) or try self.hasDynamicObservers(topic, @intFromEnum(change_type)));
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
        try pool.addObserver(py.allocator, topic, observer, change_types);
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

    pub fn notifyInternal(self: *Self, topic: *Str, args: anytype, change_types: u8) !void {
        if (self.staticObserverPool()) |pool| {
            try pool.notify(py.allocator, topic, args, change_types);
        }
        if (self.dynamicObserverPool()) |pool| {
            try pool.notify(py.allocator, topic, args, change_types);
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
            return py.returnBool(self.hasDynamicObservers(@ptrCast(args[0]), @intFromEnum(ChangeType.ANY)) catch return null);
        }
        return py.typeErrorObject(null, "Invalid arguments. Signature is has_observers(topic: Optional[str] = None)", .{});
    }

    pub fn has_observer(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n != 2 or !Str.check(args[0]) or !args[1].isCallable()) {
            return py.typeErrorObject(null, "Invalid arguments. Signature is has_observer(topic: str, observer: Callable)", .{});
        }
        return py.returnBool(self.hasDynamicObserver(@ptrCast(args[0]), args[1], @intFromEnum(ChangeType.ANY)) catch return null);
    }

    pub fn observe(self: *Self, args: [*]*Object, n: isize) ?*Object {
        const msg = "Invalid arguments. Signature is observe(topics: str | Iterable[str], observer: Callable, change_types: int=0xff)";
        if (n < 2 or n > 3 or !args[1].isCallable()) {
            return py.typeErrorObject(null, msg, .{});
        }
        const topic = args[0];
        const callback = args[1];
        const change_types: u8 = blk: {
            if (n == 3) {
                const v = args[2];
                if (!Int.check(v)) {
                    return py.typeErrorObject(null, msg, .{});
                }
                break :blk Int.as(@ptrCast(v), u8) catch return null;
            }
            break :blk @intFromEnum(ChangeType.ANY);
        };
        if (Str.check(topic)) {
            self.addDynamicObserver(@ptrCast(topic), callback, change_types) catch return null;
        } else {
            const iter = topic.iter() catch return null;
            defer iter.decref();
            while (iter.next() catch return null) |item| {
                defer item.decref();
                if (!Str.check(item)) {
                    return py.typeErrorObject(null, msg, .{});
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
        return py.typeErrorObject(null, "Invalid arguments. Signature is unobserve(topic: Optional[str]=None, observer: Optional[Callable]=None)", .{});
    }

    pub fn notify(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n < 1 or n > 2 or !Str.check(args[0])) {
            return py.typeErrorObject(null, "Invalid arguments. Signature is notify(topic: str, change = None)", .{});
        }
        const topic: *Str = @ptrCast(args[0]);
        if (n == 2) {
            self.notifyInternal(topic, .{args[1]}, @intFromEnum(ChangeType.ANY)) catch return null;
        } else {
            self.notifyInternal(topic, .{}, @intFromEnum(ChangeType.ANY)) catch return null;
        }
        return py.returnNone();
    }

    pub fn get_member(cls: *Object, name: *Object) ?*Object {
        if (!AtomMeta.check(@ptrCast(cls))) {
            // @branchHint(.cold);
            return py.typeErrorObject(null, "Atom must be defined with AtomMeta as a metatype", .{});
        }
        const meta: *AtomMeta = @ptrCast(cls);
        return meta.get_member(name);
    }

    pub fn get_members(cls: *Object) ?*Object {
        if (!AtomMeta.check(@ptrCast(cls))) {
            // @branchHint(.cold);
            return py.typeErrorObject(null, "Atom must be defined with AtomMeta as a metatype", .{});
        }
        const meta: *AtomMeta = @ptrCast(cls);
        return meta.get_atom_members();
    }

    pub fn sizeof(self: *Self) ?*Object {
        var size: usize = @sizeOf(Self);
        if (self.info.slot_count > 1) {
            // One slot is already counted for in A
            size += (self.info.slot_count - 1) * @sizeOf(?*Object);
        }
        if (self.dynamicObserverPool()) |pool| {
            size += pool.sizeof();
        }
        return @ptrCast(Int.newUnchecked(size));
    }

    // --------------------------------------------------------------------------
    // Type def
    // --------------------------------------------------------------------------
    pub fn dealloc(self: *Self) void {
        if (self.info.has_atomref) {
            AtomRef.release(self);
        }
        self.gcUntrack();
        _ = self.clear();
        if (self.dynamicObserverPool() != null) {
            const meta: *AtomMeta = @ptrCast(self.typeref());
            meta.pool_manager.?.release(py.allocator, self.info.pool_index) catch {};
        }
        self.typeref().free(@ptrCast(self));
    }

    pub fn clear(self: *Self) c_int {
        if (comptime @import("api.zig").debug_level.clears) {
            py.print("Atom.clear({s})\n", .{self.typeName()}) catch return -1;
        }
        if (self.dynamicObserverPool()) |pool| {
            pool.clear(py.allocator) catch return -1;
        }

        // Since some members fill slots with other data, the slot might not be a *Object
        // so only clear those that are pointers
        const meta: *AtomMeta = @ptrCast(self.typeref());
        std.debug.assert(meta.typeCheckSelf());
        if (meta.atom_members) |members| {
            for (members.items) |member| {
                if (member.info.storage_mode == .pointer and member.info.index < self.info.slot_count) {
                    @setRuntimeSafety(false);
                    py.clear(&self.slots[member.info.index]);
                }
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

        // Since some members fill slots with other data, the slot might not be a *Object
        // so only visit those that are pointers
        const meta: *AtomMeta = @ptrCast(self.typeref());
        std.debug.assert(meta.typeCheckSelf());
        if (meta.atom_members) |members| {
            for (members.items) |member| {
                if (member.info.storage_mode == .pointer and member.info.index < self.info.slot_count) {
                    @setRuntimeSafety(false);
                    const slot = self.slots[member.info.index];
                    if (comptime @import("api.zig").debug_level.traverse) {
                        if (@import("api.zig").debug_level.matches(member.name)) {
                            py.print("Atom.traverse({s}, member=", .{self}) catch return -1;
                            py.print("(name: {?s}, info: {}, owner: {?s}, meta: {?s}, default_context: {?s}, validate_context: {?s}, coercer_context: {?s})", .{
                                member.name,
                                member.info,
                                member.owner,
                                member.metadata,
                                member.default_context,
                                member.validate_context,
                                member.coercer_context,
                            }) catch return -1;
                            py.print(", slot type: '{s}' slot type refs: {})\n", .{
                                if (slot) |o| o.typeName() else "null",
                                if (slot) |o| o.typeref().refcnt() else 0,
                            }) catch return -1;
                        }
                    }
                    const r = py.visit(slot, visit, arg);
                    if (r != 0)
                        return r;
                }
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
        .{ .ml_name = "notify", .ml_meth = @constCast(@ptrCast(&notify)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Call the registered observers for a given topic with positional and keyword arguments." },
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
        .name = package_name ++ ".Atom",
        .basicsize = @sizeOf(Self),
        .flags = (py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_BASETYPE | py.c.Py_TPFLAGS_HAVE_GC),
        .slots = @constCast(@ptrCast(&type_slots)),
    };

    pub fn initType() !void {
        if (TypeObject != null) return;
        if (AtomMeta.TypeObject == null) {
            return py.systemError("AtomMeta type not ready", .{});
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
    const size = @sizeOf(Atom);
    if (size != 32) {
        @compileLog("Expected 32 bytes got {}", .{size});
    }
}

pub const AtomRef = extern struct {
    const Self = @This();
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*py.Type = null;
    const AtomRefMap = std.AutoArrayHashMapUnmanaged(*Atom, *AtomRef);
    var map: AtomRefMap = .{};

    base: Object,
    atom: ?*Atom, // This is not tracked

    pub usingnamespace py.ObjectProtocol(Self);

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *const Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    pub fn new(cls: *Type, args: *Tuple, kwargs: ?*Dict) ?*Self {
        return newOrError(cls, args, kwargs) catch return null;
    }

    pub fn newOrError(cls: *Type, args: *Tuple, _: ?*Dict) !*Self {
        var atom: *Atom = undefined;
        try args.parseTyped(.{&atom});
        if (map.get(atom)) |ref| {
            return ref.newref();
        }
        const ref: *Self = @ptrCast(try cls.genericNew(null, null));
        errdefer ref.decref();
        ref.atom = atom; // Do not incref
        atom.info.has_atomref = true;
        map.put(py.allocator, atom, ref) catch {
            try py.memoryError();
        };
        return ref;
    }

    pub fn call(self: *Self, args: *Tuple, kwargs: ?*Dict) ?*Object {
        const kwlist = [_:null][*c]const u8{};
        py.parseTupleAndKeywords(args, kwargs, ":__call__", @ptrCast(&kwlist), .{}) catch return null;
        if (self.atom) |atom| {
            return @ptrCast(atom.newref());
        }
        return py.returnNone();
    }

    // Clear the atomref
    pub fn release(atom: *Atom) void {
        if (map.fetchSwapRemove(atom)) |entry| {
            entry.value.atom = null;
            atom.info.has_atomref = false;
        }
    }

    pub fn __bool__(self: *Self) c_int {
        return @intFromBool(self.atom != null);
    }

    pub fn dealloc(self: *Self) void {
        if (self.atom) |atom| {
            atom.info.has_atomref = false;
            _ = map.swapRemove(atom);
        }
        self.typeref().free(@ptrCast(self));
    }

    const type_slots = [_]py.TypeSlot{
        .{ .slot = py.c.Py_tp_new, .pfunc = @constCast(@ptrCast(&new)) },
        .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
        .{ .slot = py.c.Py_tp_call, .pfunc = @constCast(@ptrCast(&call)) },
        .{ .slot = py.c.Py_nb_bool, .pfunc = @constCast(@ptrCast(&__bool__)) },
        .{}, // sentinel
    };

    pub var TypeSpec = py.TypeSpec{
        .name = package_name ++ ".AtomRef",
        .basicsize = @sizeOf(Self),
        .flags = py.c.Py_TPFLAGS_DEFAULT,
        .slots = @constCast(@ptrCast(&type_slots)),
    };

    pub fn initType() !void {
        if (TypeObject != null) return;
        TypeObject = try py.Type.fromSpec(&TypeSpec);
    }

    pub fn deinitType() void {
        py.clear(&TypeObject);
    }
};

pub fn initModule(mod: *py.Module) !void {
    frozen_str = try py.Str.internFromString("--frozen");
    errdefer py.clear(&frozen_str);
    try Atom.initType();
    errdefer Atom.deinitType();

    try AtomRef.initType();
    errdefer AtomRef.deinitType();

    // The metaclass generates subclasses
    try mod.addObjectRef("Atom", @ptrCast(Atom.TypeObject.?));
    try mod.addObjectRef("atomref", @ptrCast(AtomRef.TypeObject.?));
}

pub fn deinitModule(_: *py.Module) void {
    py.clear(&frozen_str);
    Atom.deinitType();
    AtomRef.deinitType();
}
