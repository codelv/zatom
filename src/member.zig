const py = @import("py.zig");
const Type = py.Type;
const Metaclass = py.Metaclass;
const Object = py.Object;
const Str = py.Str;
const Int = py.Int;
const Dict = py.Dict;
const Tuple = py.Tuple;

// Thes strings are set at startup
var default_name_str: ?*Str = null;


const AtomBase = @import("atom.zig").AtomBase;
const MemberObservers = @import("observer_pool.zig").MemberObservers;
const package_name = @import("api.zig").package_name;
const scalars = @import("members/scalars.zig");
const event = @import("members/event.zig");

pub const StorageMode = enum(u2) {
    slot = 0, // Takes a full slot
    bit = 1, // Takes a single bit of a slot
    none = 2, // Does not require any storage
};

pub const DefaultMode = enum(u1) { static = 0, call = 1 };

pub const Ownership = enum(u1) { stolen = 0, borrowed = 1 };

pub const MemberInfo = packed struct {
    index: u16,
    bit: u5, // bool bitfield
    storage_mode: StorageMode,
    default_mode: DefaultMode,
    // frozen: bool,
    reserved: u8, // Reduce this to so @sizeOf(MemberInfo) == 32 bits
};

// Base Member class
pub const MemberBase = extern struct {
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;
    pub const BaseType = Object.BaseType;
    const Self = @This();

    base: BaseType,
    // TODO: Observers
    observers: ?*MemberObservers = null,
    metadata: ?*Dict = null,
    default_context: ?*Object = null,
    validate_context: ?*Object = null,
    coercer_context: ?*Object = null,
    name: ?*Str = null,
    info: MemberInfo,

    // Import the object protocol
    pub usingnamespace py.ObjectProtocol(@This());

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    pub fn new(cls: *Type, args: *Tuple, kwargs: ?*Dict) ?*Self {
        const self: *Self = @ptrCast(cls.genericNew(args, kwargs) catch return null);
        self.name = default_name_str.?.newref();
        return self;
    }

    pub fn get_name(self: *Self) *Str {
        return self.name.?.newref();
    }

    pub fn set_name(self: *Self, value: *Object, _: ?*anyopaque) c_int {
        if (!Str.checkExact(value)) {
            _ = py.typeError("Member name must be a str", .{});
            return -1;
        }
        py.setref(@ptrCast(&self.name), value.newref());
        Str.internInPlace(@ptrCast(&self.name));
        return 0;
    }

    pub fn get_index(self: *Self) ?*Int {
        return Int.fromNumberUnchecked(self.info.index);
    }

    pub fn set_index(self: *Self, value: ?*Object, _: ?*anyopaque) c_int {
        if (value) |v| {
            if (!Int.check(v)) {
                _ = py.typeError("Member index must be an int", .{});
                return -1;
            }
            self.info.index = Int.as(@ptrCast(v), u16) catch return -1;
            return 0;
        }
        _ = py.typeError("Member index cannot be deleted", .{});
        return -1;
    }

    pub fn get_bit(self: *Self) ?*Int {
        return Int.fromNumberUnchecked(self.info.bit);
    }

    pub fn set_bit(self: *Self, value: ?*Object, _: ?*anyopaque) c_int {
        if (value) |v| {
            if (!Int.check(v)) {
                _ = py.typeError("Member bit must be an int", .{});
                return -1;
            }
            self.info.bit = Int.as(@ptrCast(v), u5) catch return -1;
            return 0;
        }
        _ = py.typeError("Member bit cannot be deleted", .{});
        return -1;
    }

    pub fn get_metadata(self: *Self) ?*Dict {
        if (self.metadata == null) {
            self.metadata = Dict.new() catch return null;
        }
        return self.metadata.?.newref();
    }

    pub fn set_metadata(self: *Self, value: ?*Object, _: ?*anyopaque) c_int {
        if (value) |v| {
            if (v == py.None()) {
                py.xsetref(@ptrCast(&self.metadata), null);
                return 0;
            } else if (!Dict.check(v)) {
                _ = py.typeError("Member metadata must be a dict", .{});
                return -1;
            }
        }
        py.xsetref(@ptrCast(&self.metadata), value);
        return 0;
    }

    pub fn get_slot(self: *Self, atom: *AtomBase) ?*Object {
        if (self.info.storage_mode == .slot) {
            if (!atom.typeCheckSelf()) {
                return py.typeError("Atom", .{});
            }
            if (atom.slotPtr(self.info.index)) |ptr| {
                return ptr.*;
            }
        }
        return py.attributeError("Member has no slot", .{});
    }

    pub fn set_slot(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n != 2) {
            return py.attributeError("set_slot takes 2 arguments", .{});
        }
        if (self.info.storage_mode == .slot) {
            const atom: *AtomBase = @ptrCast(args[0]);
            if (!atom.typeCheckSelf()) {
                return py.typeError("Atom", .{});
            }
            if (atom.slotPtr(self.info.index)) |ptr| {
                ptr.* = args[1];
                return py.returnNone();
            }
        }
        return py.attributeError("Member has no slot", .{});
    }

    pub fn del_slot(self: *Self, atom: *AtomBase) ?*Object {
        if (self.info.storage_mode == .slot) {
            if (!atom.typeCheckSelf()) {
                return py.typeError("Atom", .{});
            }
            if (atom.slotPtr(self.info.index)) |ptr| {
                ptr.* = null;
                return py.returnNone();
            }
        }
        return py.attributeError("Member has no slot", .{});
    }

    pub fn has_observers(self: *Self) ?*Object {
        return py.returnBool(self.hasObserversInternal());
    }

    pub fn hasObserversInternal(self: *Self) bool {
        if (self.observers) |pool| {
            return pool.has_observers();
        }
        return false;
    }

    pub fn has_observer(self: *Self, args: [*]*Object, n: isize) ?*Object {
        var change_types: u8 = 0xff;
        if (n < 1 or n > 2) {
            return py.typeError("has_observer takes 1 or 2 arguments");
        }
        if (n == 2) {
            if (!Int.check(args[1])) {
                return py.typeError("has_observer 2nd arg must be an int");
            }
            change_types = Int.as(@ptrCast(args[1]), u8) catch return null;
        }
        if (self.observers) |pool| {
            return py.returnBool(pool.has_observer(args[0], change_types) catch return null);
        }
        return py.returnFalse();
    }


    pub fn remove_static_observer(self: *Self, observer: *Object) ?*Object {
        if (self.observers) |pool| {
            pool.remove_observer(observer) catch return null;
        }
        return py.returnNone();
    }

    // Generic notify
    pub fn notify(self: *Self, atom: *AtomBase, change: *Dict) !void {
        _ = self;
        _ = atom;
        _ = change;
    }

    pub fn notifyCreate(self: *Self, atom: *AtomBase, newvalue: *Object) !void {
        _ = self;
        _ = atom;
        _ = newvalue;
        // TODO: Implement
    }

    pub fn notifyUpdate(self: *Self, atom: *AtomBase, oldvalue: *Object, newvalue: *Object) !void {
        _ = self;
        _ = atom;
        _ = oldvalue;
        _ = newvalue;
        // TODO: Implement
    }

    pub fn notifyDelete(self: *Self, atom: *AtomBase, oldvalue: *Object) !void {
        _ = self;
        _ = atom;
        _ = oldvalue;
        // TODO: Implement
    }

    pub fn clone(self: *Self) ?*Object {
        return self.cloneInternal() catch return null;
    }

    pub fn cloneInternal(self: *Self) !*Object {
        const result: *Self = @ptrCast(try self.typeref().genericNew(null, null));
        errdefer result.decref();
        result.info = self.info;
        result.name = self.name.?.newref();
        errdefer result.name.?.decref();

        if (self.metadata) |metadata| {
            result.metadata = try metadata.copy();
        }
        errdefer if (result.metadata) |metadata| metadata.decref();

        if (self.default_context) |context| {
            result.default_context = context.newref();
        }
        errdefer if (result.default_context) |context| context.decref();

        if (self.validate_context) |context| {
            result.validate_context = context.newref();
        }
        errdefer if (result.validate_context) |context| context.decref();
        if (self.coercer_context) |context| {
            result.coercer_context = context.newref();
        }
        errdefer if (result.coercer_context) |context| context.decref();

        return @ptrCast(result);
    }

    // AtomBase uses this to selectively clear slots
    pub fn clearSlot(self: *Self, atom: *AtomBase) void {
        if (self.info.storage_mode == .slot) {
            if (atom.slotPtr(self.info.index)) |ptr| {
                py.clear(ptr);
            }
        }
    }

    // AtomBase uses this to selectively visit slots
    pub fn visitSlot(self: *Self, atom: *AtomBase, visit: py.visitproc, arg: ?*anyopaque) c_int {
        if (self.info.storage_mode == .slot) {
            if (atom.slotPtr(self.info.index)) |ptr| {
                return py.visit(ptr.*, visit, arg);
            }
        }
        return 0;
    }

    pub fn dealloc(self: *Self) void {
        self.gcUntrack();
        _ = self.clear();
        self.typeref().free(@ptrCast(self));
    }

    pub fn clear(self: *Self) c_int {
        py.clearAll(.{
            &self.name,
            &self.metadata,
            &self.default_context,
            &self.validate_context,
            &self.coercer_context,
        });
        return 0;
    }

    // Check if object is an atom_meta
    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        return py.visitAll(.{
            self.name,
            self.metadata,
            self.default_context,
            self.validate_context,
            self.coercer_context,
        }, visit, arg);
    }

    const getset = [_]py.GetSetDef{
        .{ .name = "name", .get = @ptrCast(&get_name), .set = @ptrCast(&set_name), .doc = "Get and set the name to which the member is bound." },
        .{ .name = "index", .get = @ptrCast(&get_index), .set = @ptrCast(&set_index), .doc = "Get the index to which the member is bound." },
        .{ .name = "bit", .get = @ptrCast(&get_bit), .set = @ptrCast(&set_bit), .doc = "Get the index to which the member is bound." },
        .{ .name = "metadata", .get = @ptrCast(&get_metadata), .set = @ptrCast(&set_metadata), .doc = "Get and set the member metadata" },
        .{}, // sentinel
    };

    const methods = [_]py.MethodDef{
        .{ .ml_name = "get_slot", .ml_meth = @constCast(@ptrCast(&get_slot)), .ml_flags = py.c.METH_O, .ml_doc = "Get slot value directly" },
        .{ .ml_name = "set_slot", .ml_meth = @constCast(@ptrCast(&set_slot)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Set slot value directly" },
        .{ .ml_name = "del_slot", .ml_meth = @constCast(@ptrCast(&del_slot)), .ml_flags = py.c.METH_O, .ml_doc = "Del slot value directly" },
        .{ .ml_name = "clone", .ml_meth = @constCast(@ptrCast(&clone)), .ml_flags = py.c.METH_NOARGS, .ml_doc = "Clone the member" },
        .{}, // sentinel
    };

    const type_slots = [_]py.TypeSlot{
        .{ .slot = py.c.Py_tp_new, .pfunc = @constCast(@ptrCast(&new)) },
        .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
        .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
        .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
        .{ .slot = py.c.Py_tp_methods, .pfunc = @constCast(@ptrCast(&methods)) },
        .{ .slot = py.c.Py_tp_getset, .pfunc = @constCast(@ptrCast(&getset)) },
        //.{ .slot = py.c.Py_tp_descr_get, .pfunc = @constCast(@ptrCast(&__get__)) },
        //.{ .slot = py.c.Py_tp_descr_set, .pfunc = @constCast(@ptrCast(&__set__)) },
        .{}, // sentinel
    };
    pub var TypeSpec = py.TypeSpec{
        .name = package_name ++ ".Member",
        .basicsize = @sizeOf(Self),
        .flags = (py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_BASETYPE | py.c.Py_TPFLAGS_HAVE_GC),
        .slots = @constCast(@ptrCast(&type_slots)),
    };

    pub fn initType() !void {
        if (TypeObject != null) return;
        TypeObject = try Type.fromSpec(&TypeSpec);
    }

    pub fn deinitType() void {
        py.clear(&TypeObject);
    }
};

// Create a member subclass with the given mode
pub fn Member(comptime type_name: [:0]const u8, comptime impl: type) type {
    return extern struct {
        pub var TypeObject: ?*Type = null;
        pub const BaseType = MemberBase;
        pub const TypeName = type_name;
        pub const Impl = impl;
        const Self = @This();

        base: BaseType,

        // Import the object protocol
        pub usingnamespace py.ObjectProtocol(@This());

        // Type check the given object. This assumes the module was initialized
        pub fn check(obj: *Object) bool {
            return obj.typeCheck(TypeObject.?);
        }

        pub fn init(self: *Self, args: *Tuple, kwargs: ?*Dict) c_int {
            if (comptime @hasDecl(impl, "storage_mode")) {
                self.base.info.storage_mode = impl.storage_mode;
            }
            if (comptime @hasDecl(impl, "default_mode")) {
                self.base.info.default_mode = impl.default_mode;
            }
            if (comptime @hasDecl(impl, "init")) {
                impl.init(@ptrCast(self), args, kwargs) catch return -1;
            } else {
                const kwlist = [_:null][*c]const u8{
                    "default",
                    "factory",
                };
                var default_context: ?*Object = null;
                var default_factory: ?*Object = null;
                py.parseTupleAndKeywords(args, kwargs, "|OO", @ptrCast(&kwlist), .{ &default_context, &default_factory }) catch return -1;

                if (default_context) |context| {
                    self.base.default_context = context.newref();
                } else if (comptime @hasDecl(impl, "initDefault")) {
                    self.base.default_context = impl.initDefault() catch return -1;
                }
            }
            return 0;
        }

        pub fn __get__(self: *Self, cls: ?*AtomBase, _: ?*Object) ?*Object {
            if (cls) |atom| {
                if (!atom.typeCheckSelf()) {
                    return py.typeError("Members can only be used on Atom objects", .{});
                }
                const handler = comptime if (@hasDecl(impl, "getattr")) impl.getattr else Self.getattr;
                return handler(@ptrCast(self), atom) catch null;
            }
            return @ptrCast(self.newref());
        }

        pub fn __set__(self: *Self, atom: *AtomBase, value: ?*Object) c_int {
            if (!atom.typeCheckSelf()) {
                _ = py.typeError("Members can only be used on Atom objects", .{});
                return -1;
            }
            if (value) |v| {
                const handler = comptime if (@hasDecl(impl, "setattr")) impl.setattr else Self.setattr;
                handler(@ptrCast(self), atom, v) catch return -1;
            } else {
                const handler = comptime if (@hasDecl(impl, "delattr")) impl.delattr else Self.delattr;
                handler(@ptrCast(self), atom) catch return -1;
            }
            return 0;
        }

        // Returns new reference
        pub fn default(self: *Self, atom: *AtomBase) !*Object {
            _ = atom;
            switch (self.base.info.default_mode) {
                .static => {
                    if (self.base.default_context) |value| {
                        return value.newref();
                    }
                    return py.returnNone();
                },
                .call => {
                    if (self.base.default_context) |callable| {
                        return callable.callArgs(.{});
                    } else {
                        _ = py.systemError("default context missing", .{});
                        return error.PyError;
                    }
                },
            }
        }

        // Default write slot implementation. It does not need to worry about discarding the old value but must
        // return whether it stole a reference to value or borrowed it so the caller can know how to handle it.
        pub inline fn writeSlot(self: *MemberBase, atom: *AtomBase, slot: *?*Object, value: *Object) py.Error!Ownership {
            if (comptime @hasDecl(impl, "writeSlot")) {
                return try impl.writeSlot(self, atom, slot, value);
            } else {
                slot.* = value;
                return .stolen;
            }
        }

        // Default delete slot implementation. It does not need to worry about discarding the old value
        pub inline fn deleteSlot(self: *MemberBase, atom: *AtomBase, slot: *?*Object) void {
            if (comptime @hasDecl(impl, "deleteSlot")) {
                impl.deleteSlot(self, atom, slot);
            } else {
                slot.* = null;
            }
        }

        // Default read slot implementation. Must return a new reference
        pub inline fn readSlot(self: *MemberBase, atom: *AtomBase, slot: *?*Object) py.Error!?*Object {
            if (comptime @hasDecl(impl, "readSlot")) {
                return impl.readSlot(self, atom, slot);
            }
            if (slot.*) |value| {
                return value.newref();
            }
            return null;
        }


        // Default getattr implementation provides normal slot behavior
        // Returns new reference
        pub fn getattr(self: *Self, atom: *AtomBase) !*Object {
            if (atom.slotPtr(self.base.info.index)) |ptr| {
                // TODO: This will never call notifyCreate for the Bool member
                if (try readSlot(@ptrCast(self), atom, ptr)) |v| {
                    return v;
                }
                const old = py.None();
                defer old.decref(); // TODO: None does not need decref on 3.12+
                const default_handler = comptime if (@hasDecl(impl, "default")) impl.default else Self.default;
                const value = try default_handler(@ptrCast(self), atom);

                // We must track whether the write took ownership of the default value
                // becuse it is needed in notify create. If the writeSlot says it took ownership
                // of the value then we do not need to decref it. If an error occurs it gets decref'd
                var value_ownership: Ownership = .borrowed;
                defer if (value_ownership == .borrowed) value.decref();
                try self.validate(atom, old, value);
                value_ownership = try writeSlot(@ptrCast(self), atom, ptr, value); // Default returns a new object
                try self.base.notifyCreate(atom, value);
                return value.newref();
            } else {
                // @branchHint(.cold);
                _ = py.attributeError("Member %s has no slot", .{self.base.name});
                return error.PyError;
            }
        }

        // Default setattr implementation provides normal slot behavior
        pub fn setattr(self: *Self, atom: *AtomBase, value: *Object) !void {
            if (atom.slotPtr(self.base.info.index)) |ptr| {
                if (atom.info.is_frozen) {
                    // @branchHint(.unlikely);
                    _ = py.attributeError("Can't set attribute of frozen Atom", .{});
                    return error.PyError;
                }

                if (ptr.*) |old| {
                    try self.validate(atom, old, value);
                    const r = try writeSlot(@ptrCast(self), atom, ptr, value.newref());
                    defer old.decref();
                    defer if (r == .borrowed) value.decref();
                    try self.base.notifyUpdate(atom, old, value);
                } else {
                    const old = py.returnNone();
                    defer old.decref();
                    try self.validate(atom, old, value);
                    const r = try writeSlot(@ptrCast(self), atom, ptr, value.newref());
                    defer if (r == .borrowed) value.decref();
                    try self.base.notifyCreate(atom, value);
                }

                return; // Ok
            } else {
                // @branchHint(.cold);
                _ = py.attributeError("Member has no slot", .{});
                return error.PyError;
            }
        }

        // Default delattr implementation
        pub fn delattr(self: *Self, atom: *AtomBase) !void {
            if (atom.info.is_frozen) {
                // @branchHint(.unlikely);
                _ = py.attributeError("Can't delete attribute of frozen Atom", .{});
                return error.PyError;
            }
            if (atom.slotPtr(self.base.info.index)) |ptr| {
                if (ptr.*) |value| {
                    defer value.decref();
                    deleteSlot(@ptrCast(self), atom, ptr);
                    try self.base.notifyDelete(atom, value);
                }
                // Else nothing to do
            } else {
                // @branchHint(.cold);
                _ = py.attributeError("Member has no slot", .{});
                return error.PyError;
            }
        }

        pub inline fn validate(self: *Self, atom: *AtomBase, oldvalue: *Object, newvalue: *Object) !void {
            if (comptime @hasDecl(impl, "validate")) {
                return impl.validate(@ptrCast(self), atom, oldvalue, newvalue);
            }
            // else do nothing
        }

        const type_slots = [_]py.TypeSlot{
            .{ .slot = py.c.Py_tp_init, .pfunc = @constCast(@ptrCast(&init)) },
            .{ .slot = py.c.Py_tp_descr_get, .pfunc = @constCast(@ptrCast(&__get__)) },
            .{ .slot = py.c.Py_tp_descr_set, .pfunc = @constCast(@ptrCast(&__set__)) },
            .{}, // sentinel
        };
        pub var TypeSpec = py.TypeSpec{
            .name = package_name ++ "." ++ TypeName,
            .basicsize = @sizeOf(Self),
            .flags = (py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_BASETYPE),
            .slots = @constCast(@ptrCast(&type_slots)),
        };

        pub fn initType() !void {
            if (TypeObject != null) return;
            TypeObject = try Type.fromSpecWithBases(&TypeSpec, @ptrCast(MemberBase.TypeObject.?));
        }

        pub fn deinitType() void {
            py.clear(&TypeObject);
        }
    };
}

pub fn initModule(mod: *py.Module) !void {
    default_name_str = try py.Str.internFromString("<undefined>");
    errdefer py.clear(&default_name_str);
    try MemberBase.initType();
    errdefer MemberBase.deinitType();
    try mod.addObjectRef("Member", @ptrCast(MemberBase.TypeObject.?));

    try scalars.initModule(mod);
    errdefer scalars.deinitModule(mod);

    try event.initModule(mod);
    errdefer event.deinitModule(mod);
}

pub fn deinitModule(mod: *py.Module) void {
    py.clear(&default_name_str);
    MemberBase.deinitType();
    scalars.deinitModule(mod);
    event.deinitModule(mod);
}
