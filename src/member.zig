const py = @import("py.zig");
const std = @import("std");
const Type = py.Type;
const Metaclass = py.Metaclass;
const Object = py.Object;
const Str = py.Str;
const Int = py.Int;
const Dict = py.Dict;
const Tuple = py.Tuple;

// Thes strings are set at startup
var undefined_str: ?*Str = null;
var type_str: ?*Str = null;
var create_str: ?*Str = null;
var update_str: ?*Str = null;
var delete_str: ?*Str = null;
var name_str: ?*Str = null;
var object_str: ?*Str = null;
var value_str: ?*Str = null;
var oldvalue_str: ?*Str = null;

const AtomBase = @import("atom.zig").AtomBase;
const AtomMeta = @import("atom_meta.zig").AtomMeta;
const ObserverPool = @import("observer_pool.zig").ObserverPool;
const ChangeType = @import("observer_pool.zig").ChangeType;
const package_name = @import("api.zig").package_name;

const MAX_BITSIZE = @bitSizeOf(usize);
const MAX_OFFSET = @bitSizeOf(usize) - 1;

pub const StorageMode = enum(u2) {
    pointer = 0, // Object pointer
    static = 1, // Takes a fixed width of a slot
    none = 2, // Does not require any storage
};

pub const Ownership = enum(u1) { stolen = 0, borrowed = 1 };
pub const DefaultMode = enum(u1) { static = 0, call = 1 };

pub const MemberInfo = packed struct {
    index: u16,
    width: u6, // bit size -1. A value of 0 means 1 one bit
    offset: u6, // starting bit position in slot
    storage_mode: StorageMode,
    default_mode: DefaultMode,
    // It is up to the member whether these is used or not
    optional: bool,
};

// Base Member class
pub const MemberBase = extern struct {
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;
    pub const BaseType = Object.BaseType;
    const Self = @This();

    base: BaseType,
    metadata: ?*Dict = null,
    default_context: ?*Object = null,
    validate_context: ?*Object = null,
    coercer_context: ?*Object = null,
    name: *Str = undefined,
    // The class to which this member is bound
    owner: ?*AtomMeta = null,
    info: MemberInfo,

    // Import the object protocol
    pub usingnamespace py.ObjectProtocol(@This());

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    pub fn new(cls: *Type, args: *Tuple, kwargs: ?*Dict) ?*Self {
        const self: *Self = @ptrCast(cls.genericNew(args, kwargs) catch return null);
        self.name = undefined_str.?.newref();
        return self;
    }

    // --------------------------------------------------------------------------
    // Properties
    // --------------------------------------------------------------------------

    pub fn get_name(self: *Self) *Str {
        return self.name.newref();
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

    pub fn get_index(self: *Self) ?*Object {
        if (self.info.storage_mode == .none) {
            return py.returnNone();
        }
        return @ptrCast(Int.fromNumberUnchecked(self.info.index));
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

    pub fn get_bitsize(self: *Self) ?*Int {
        return Int.fromNumberUnchecked(@as(usize, self.info.width) + 1);
    }

    pub fn set_bitsize(self: *Self, value: ?*Object, _: ?*anyopaque) c_int {
        if (value) |v| {
            if (!Int.check(v)) {
                _ = py.typeError("Member bitsize must be an int", .{});
                return -1;
            }
            const n = Int.as(@ptrCast(v), usize) catch return -1;
            if (n == 0 or n > MAX_BITSIZE) {
                _ = py.typeError("Member bitsize must be between 1 and {}", .{MAX_BITSIZE});
                return -1;
            }
            self.info.width = @intCast(n - 1);
            return 0;
        }
        _ = py.typeError("Member bitsize cannot be deleted", .{});
        return -1;
    }

    pub fn get_offset(self: *Self) ?*Int {
        return Int.fromNumberUnchecked(self.info.offset);
    }

    pub fn set_offset(self: *Self, value: ?*Object, _: ?*anyopaque) c_int {
        if (value) |v| {
            if (!Int.check(v)) {
                _ = py.typeError("Member offset must be an int", .{});
                return -1;
            }
            const n = Int.as(@ptrCast(v), usize) catch return -1;
            if (n > MAX_OFFSET) {
                _ = py.typeError("Member offset must be between 0 and {}", .{MAX_OFFSET});
                return -1;
            }
            self.info.offset = @intCast(n);
            return 0;
        }
        _ = py.typeError("Member offset cannot be deleted", .{});
        return -1;
    }

    pub fn get_owner(self: *Self) ?*Object {
        if (self.owner) |owner| {
            return @ptrCast(owner.newref());
        }
        return null;
    }

    pub fn get_metadata(self: *Self) ?*Object {
        if (self.metadata) |metadata| {
            return @ptrCast(metadata.newref());
        }
        return py.returnNone();
    }

    pub fn set_metadata(self: *Self, value: ?*Object, _: ?*anyopaque) c_int {
        if (value == null or value.?.isNone()) {
            py.xsetref(@ptrCast(&self.metadata), null);
            return 0;
        } else if (Dict.check(value.?)) {
            py.xsetref(@ptrCast(&self.metadata), value);
            return 0;
        }
        _ = py.typeError("Member metadata must be a dict or None", .{});
        return -1;
    }

    // --------------------------------------------------------------------------
    // Methods
    // --------------------------------------------------------------------------
    pub fn get_slot(self: *Self, atom: *AtomBase) ?*Object {
        if (self.info.storage_mode != .none) {
            if (!atom.typeCheckSelf()) {
                return py.typeError("Atom", .{});
            }
            if (atom.slotPtr(self.info.index)) |ptr| {
                switch (self.info.storage_mode) {
                    .pointer => return ptr.*,
                    .static => {
                        const data_ptr: *usize = @ptrCast(ptr);
                        if (data_ptr.* & self.slotSetMask() != 0) {
                            const data = (data_ptr.* & self.slotDataMask()) >> self.info.offset;
                            return @ptrCast(Int.new(data) catch null);
                        }
                        return py.returnNone();
                    },
                    .none => unreachable,
                }
            }
        }
        return py.attributeError("Member has no slot", .{});
    }

    pub fn set_slot(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n != 2) {
            return py.attributeError("set_slot takes 2 arguments", .{});
        }
        if (self.info.storage_mode != .none) {
            const atom: *AtomBase = @ptrCast(args[0]);
            if (!atom.typeCheckSelf()) {
                return py.typeError("Atom", .{});
            }
            if (atom.slotPtr(self.info.index)) |ptr| {
                switch (self.info.storage_mode) {
                    .pointer => {
                        ptr.* = args[1];
                    },
                    .static => {
                        if (!Int.check(args[1])) {
                            return py.typeError("set_slot requires an int", .{});
                        }
                        const data = Int.as(@ptrCast(args[1]), usize) catch return null;
                        const max_value = std.math.pow(usize, 2, self.info.width + 1);
                        if (data < 0 or data > max_value) {
                            return py.typeError("set_slot data out of range 0..{}", .{max_value});
                        }
                        const data_ptr: *usize = @ptrCast(ptr);
                        const data_mask = self.slotDataMask();
                        const set_mask = self.slotSetMask();
                        const new_data = data_mask & (data << self.info.offset);
                        data_ptr.* = (data_ptr.* & ~data_mask) | new_data | set_mask;
                    },
                    .none => unreachable,
                }
                return py.returnNone();
            }
        }
        return py.attributeError("Member has no slot", .{});
    }

    pub fn del_slot(self: *Self, atom: *AtomBase) ?*Object {
        if (self.info.storage_mode != .none) {
            if (!atom.typeCheckSelf()) {
                return py.typeError("Atom", .{});
            }
            if (atom.slotPtr(self.info.index)) |ptr| {
                switch (self.info.storage_mode) {
                    .pointer => {
                        ptr.* = null;
                    },
                    .static => {
                        const data_ptr: *usize = @ptrCast(ptr);
                        data_ptr.* &= ~self.slotSetMask();
                    },
                    .none => unreachable,
                }
                return py.returnNone();
            }
        }
        return py.attributeError("Member has no slot", .{});
    }

    pub fn has_observers(self: *Self) ?*Object {
        if (self.staticObservers()) |pool| {
            return py.returnBool(pool.hasTopic(self.name) catch return null);
        }
        return py.returnFalse();
    }

    pub fn has_observer(self: *Self, args: [*]*Object, n: isize) ?*Object {
        const msg = "Invalid arguments. Signature is has_observer(observer: str | Callable, change_types: int = 0xff)";
        var change_types: u8 = 0xff;
        if (n < 1 or n > 2) {
            return py.typeError(msg, .{});
        }
        if (n == 2) {
            if (!Int.check(args[1])) {
                return py.typeError(msg, .{});
            }
            change_types = Int.as(@ptrCast(args[1]), u8) catch return null;
        }
        if (self.staticObservers()) |pool| {
            return py.returnBool(pool.hasObserver(self.name, args[0], change_types) catch return null);
        }
        return py.returnFalse();
    }

    pub fn add_static_observer(self: *Self, args: [*]*Object, n: isize) ?*Object {
        const msg = "Invalid arguments. Signature is add_static_observer(observer: str | Callable, change_types: int = 0xff)";
        if (n < 1 or n < 2) {
            return py.typeError(msg, .{});
        }
        const observer = args[0];
        if (!Str.check(observer) and !observer.isCallable()) {
            return py.typeError(msg, .{});
        }
        const change_types = blk: {
            if (n == 2) {
                const v = args[1];
                if (!Int.check(v)) {
                    return py.typeError(msg, .{});
                }
                break :blk Int.as(@ptrCast(v), u8) catch return null;
            }
            break :blk @intFromEnum(ChangeType.any);
        };


        if (self.staticObservers()) |pool| {
            pool.addObserver(py.allocator, self.name, observer, change_types) catch return null;
        }
        return py.returnNone();
    }

    pub fn remove_static_observer(self: *Self, observer: *Object) ?*Object {
        if (self.staticObservers()) |pool| {
            pool.removeObserver(py.allocator, self.name, observer) catch return null;
        }
        return py.returnNone();
    }

    pub fn clone(self: *Self) ?*Object {
        return self.cloneInternal() catch return null;
    }

    pub fn notify(self: *Self, args: *Tuple, kwargs: ?*Dict) ?*Object {
        const n = args.size() catch return null;
        if (n < 1) {
            return py.typeError("notify() requires at least 1 argument", .{});
        }
        const atom: *AtomBase = @ptrCast(args.getUnsafe(0).?);
        if (!atom.typeCheckSelf()) {
            return py.typeError("notify() 1st argument must be an Atom instance", .{});
        }
        const new_args = args.slice(1, n) catch return null;
        atom.notifyInternal(self.name, new_args, kwargs, @intFromEnum(ChangeType.any)) catch return null;
        return py.returnNone();
    }

    pub fn tag(self: *Self, args: *Tuple, kwargs: ?*Dict) ?*Object {
        if (args.sizeUnchecked() != 0) {
            return py.typeError("tag() takes no positional arguments", .{});
        }
        if (kwargs) |kw| {
            if (self.metadata) |metadata| {
                metadata.update(@ptrCast(kw)) catch return null;
            } else {
                self.metadata = kw.copy() catch return null;
            }
            return @ptrCast(self.newref());
        }
        return py.typeError("tag() requires keyword arguments", .{});
    }

    // --------------------------------------------------------------------------
    // Internal api
    // --------------------------------------------------------------------------
    // Helper function for validation failures
    pub fn validateFail(self: *Self, atom: *AtomBase, value: *Object, expected: [:0]const u8) py.Error!void {
        _ = py.typeError("The '{s}' member on the '{s}' object must be of type '{s}'. Got object of type '{s}' instead", .{
            self.name.data(),
            atom.typeName(),
            expected,
            value.typeName(),
        });
        return error.PyError;
    }

    pub fn validateTypeOrTupleOfTypes(self: *Self, kind: *Object) py.Error!void {
        if (Type.check(kind)) {
            return;
        } else if (Tuple.check(kind)) {
            const kinds: *Tuple = @ptrCast(kind);
            const n = try kinds.size();
            if (n == 0) {
                _ = py.typeError("{s} kind must be a type or tuple of types. Got an empty tuple", .{self.typeName()});
                return error.PyError;
            }
            for (0..n) |i| {
                const obj = kinds.getUnsafe(i).?;
                if (!Type.check(obj)) {
                    _ = py.typeError("{s} kind must be a type or tuple of types. Got a tuple with '{s}'", .{
                        self.typeName(),
                        obj.typeName(),
                    });
                    return error.PyError;
                }
            }
            return;
        } else {
            _ = py.typeError("{s} kind must be a type or tuple of types. Got an empty tuple", .{self.typeName()});
            return error.PyError;
        }
    }

    pub fn staticObservers(self: *Self) ?*ObserverPool {
        if (self.owner) |owner| {
            return owner.static_observers;
        }
        return null;
    }

    pub fn shouldNotify(self: *Self, atom: *AtomBase) bool {
        return (!atom.info.notifications_disabled and atom.hasAnyObservers(self.name) catch unreachable);
    }

    pub fn hasObserversInternal(self: *Self) bool {
        if (self.staticObservers()) |pool| {
            return pool.hasTopic(self.name) catch unreachable;
        }
        return false;
    }

    pub fn notifyChange(self: *Self, atom: *AtomBase, change: *Dict, change_type: ChangeType) !void {
        const args = try Tuple.packNewrefs(.{change});
        defer args.decref();
        try atom.notifyInternal(self.name, args, null, @intFromEnum(change_type));
    }

    pub fn notifyCreate(self: *Self, atom: *AtomBase, newvalue: *Object) !void {
        if (self.shouldNotify(atom)) {
            var change: *Dict = try Dict.new();
            defer change.decref();
            try change.set(@ptrCast(type_str.?), @ptrCast(create_str.?));
            try change.set(@ptrCast(object_str.?), @ptrCast(atom));
            try change.set(@ptrCast(name_str.?), @ptrCast(self.name));
            try change.set(@ptrCast(value_str.?), newvalue);
            return self.notifyChange(atom, change, .create);
        }
    }

    pub fn notifyUpdate(self: *Self, atom: *AtomBase, oldvalue: *Object, newvalue: *Object) !void {
        if (oldvalue != newvalue and self.shouldNotify(atom)) {
            var change: *Dict = try Dict.new();
            defer change.decref();
            try change.set(@ptrCast(type_str.?), @ptrCast(update_str.?));
            try change.set(@ptrCast(object_str.?), @ptrCast(atom));
            try change.set(@ptrCast(name_str.?), @ptrCast(self.name));
            try change.set(@ptrCast(oldvalue_str.?), oldvalue);
            try change.set(@ptrCast(value_str.?), newvalue);
            return self.notifyChange(atom, change, .update);
        }
    }

    pub fn notifyDelete(self: *Self, atom: *AtomBase, oldvalue: *Object) !void {
        if (self.shouldNotify(atom)) {
            var change: *Dict = try Dict.new();
            defer change.decref();
            try change.set(@ptrCast(type_str.?), @ptrCast(delete_str.?));
            try change.set(@ptrCast(object_str.?), @ptrCast(atom));
            try change.set(@ptrCast(name_str.?), @ptrCast(self.name));
            try change.set(@ptrCast(value_str.?), oldvalue);
            return self.notifyChange(atom, change, .delete);
        }
    }

    pub fn cloneInternal(self: *Self) !*Object {
        const result: *Self = @ptrCast(try self.typeref().genericNew(null, null));
        errdefer result.decref();
        result.info = self.info;
        result.name = self.name.newref();
        errdefer result.name.decref();

        if (self.owner) |o| {
            result.owner = o.newref();
        }
        errdefer if (result.owner) |o| o.decref();

        if (self.metadata) |metadata| {
            result.metadata = try metadata.copy();
        }
        errdefer if (result.metadata) |metadata| metadata.decref();

        inline for (.{ "default", "validate", "coercer" }) |name| {
            const field_name = name ++ "_context";
            if (@field(self, field_name)) |context| {
                @field(result, field_name) = context.newref();
            }
            errdefer if (@field(result, field_name)) |context| context.decref();
        }
        return @ptrCast(result);
    }

    // Mask for slot's data bits
    pub inline fn slotDataMask(self: *Self) usize {
        return (@as(usize, self.info.width) + 1) << self.info.offset;
    }

    // Mask for slot's 'is set' bit
    pub inline fn slotSetMask(self: *Self) usize {
        const pos: u6 = self.info.offset + self.info.width + 1;
        return @as(usize, @as(usize, 1) << pos);
    }

    // --------------------------------------------------------------------------
    // Type def
    // --------------------------------------------------------------------------
    pub fn dealloc(self: *Self) void {
        self.gcUntrack();
        _ = self.clear();
        self.typeref().free(@ptrCast(self));
    }

    pub fn clear(self: *Self) c_int {
        py.clearAll(.{
            &self.name,
            &self.owner,
            &self.metadata,
            &self.default_context,
            &self.validate_context,
            &self.coercer_context,
        });
        return 0;
    }

    // AtomBase uses this to selectively clear slots
    pub fn clearSlot(self: *Self, atom: *AtomBase) void {
        if (self.info.storage_mode == .pointer) {
            if (atom.slotPtr(self.info.index)) |ptr| {
                py.clear(ptr);
            }
        }
    }

    // AtomBase uses this to selectively visit slots
    pub fn visitSlot(self: *Self, atom: *AtomBase, visit: py.visitproc, arg: ?*anyopaque) c_int {
        if (self.info.storage_mode == .pointer) {
            if (atom.slotPtr(self.info.index)) |ptr| {
                return py.visit(ptr.*, visit, arg);
            }
        }
        return 0;
    }

    // Check if object is an atom_meta
    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        return py.visitAll(.{
            self.name,
            self.owner,
            self.metadata,
            self.default_context,
            self.validate_context,
            self.coercer_context,
        }, visit, arg);
    }

    const getset = [_]py.GetSetDef{
        .{ .name = "name", .get = @ptrCast(&get_name), .set = @ptrCast(&set_name), .doc = "Get and set the name to which the member is bound." },
        .{ .name = "index", .get = @ptrCast(&get_index), .set = @ptrCast(&set_index), .doc = "Get the index to which the member is bound." },
        .{ .name = "bitsize", .get = @ptrCast(&get_bitsize), .set = @ptrCast(&set_bitsize), .doc = "Get the bitsize of the member." },
        .{ .name = "offset", .get = @ptrCast(&get_offset), .set = @ptrCast(&set_offset), .doc = "Get the bitsize of the member." },
        .{ .name = "metadata", .get = @ptrCast(&get_metadata), .set = @ptrCast(&set_metadata), .doc = "Get and set the member metadata" },
        .{}, // sentinel
    };

    const methods = [_]py.MethodDef{
        .{ .ml_name = "get_slot", .ml_meth = @constCast(@ptrCast(&get_slot)), .ml_flags = py.c.METH_O, .ml_doc = "Get slot value directly" },
        .{ .ml_name = "set_slot", .ml_meth = @constCast(@ptrCast(&set_slot)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Set slot value directly" },
        .{ .ml_name = "del_slot", .ml_meth = @constCast(@ptrCast(&del_slot)), .ml_flags = py.c.METH_O, .ml_doc = "Del slot value directly" },
        .{ .ml_name = "notify", .ml_meth = @constCast(@ptrCast(&notify)), .ml_flags = py.c.METH_VARARGS | py.c.METH_KEYWORDS, .ml_doc = "Notify the observers for the given member and atom." },
        .{ .ml_name = "has_observers", .ml_meth = @constCast(@ptrCast(&has_observers)), .ml_flags = py.c.METH_NOARGS, .ml_doc = "Get whether or not this member has observers." },
        .{ .ml_name = "has_observer", .ml_meth = @constCast(@ptrCast(&has_observer)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Get whether or not the member already has the given observer." },
        .{ .ml_name = "add_static_observer", .ml_meth = @constCast(@ptrCast(&add_static_observer)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Add the name of a method to call on all atoms when the member changes." },
        .{ .ml_name = "remove_static_observer", .ml_meth = @constCast(@ptrCast(&remove_static_observer)), .ml_flags = py.c.METH_O, .ml_doc = "Remove the name of a method to call on all atoms when the member changes." },
        .{ .ml_name = "tag", .ml_meth = @constCast(@ptrCast(&tag)), .ml_flags = py.c.METH_VARARGS | py.c.METH_KEYWORDS, .ml_doc = "Tag the member with metadata" },
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
        pub const storage_mode: StorageMode = if (@hasDecl(impl, "storage_mode")) impl.storage_mode else .pointer;
        const Self = @This();

        base: BaseType,

        // Import the object protocol
        pub usingnamespace py.ObjectProtocol(@This());

        // Type check the given object. This assumes the module was initialized
        pub fn check(obj: *Object) bool {
            return obj.typeCheck(TypeObject.?);
        }

        // --------------------------------------------------------------------------
        // Custom member api
        // --------------------------------------------------------------------------

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
        pub inline fn writeSlot(self: *Self, atom: *AtomBase, slot: *?*Object, value: *Object) py.Error!Ownership {
            switch (comptime storage_mode) {
                .pointer => {
                    slot.* = value;
                    return .stolen;
                },
                .static => {
                    if (comptime !@hasDecl(impl, "writeSlot")) {
                        @compileError("member impl must provide a writeSlot function if storage mode is static. Signature is `pub fn writeSlot(self: *MemberBase, atom: *AtomBase, value: *Object) py.Error!usize`");
                    }
                    const ptr: *usize = @ptrCast(slot);
                    const data_mask = self.base.slotDataMask();
                    const set_mask = self.base.slotSetMask();
                    const data = try impl.writeSlot(@ptrCast(self), atom, value);
                    const new_value = data_mask & (data << self.base.info.offset);
                    // Mark the slot as set with the new data
                    ptr.* = (ptr.* & ~data_mask) | new_value | set_mask;
                    return .borrowed;
                },
                .none => {
                    // unreachable;
                    return .borrowed;
                },
            }
        }

        // Default delete slot implementation. It does not need to worry about discarding the old value
        pub inline fn deleteSlot(self: *Self, _: *AtomBase, slot: *?*Object) void {
            switch (comptime storage_mode) {
                .pointer => {
                    slot.* = null;
                },
                .static => {
                    // Clear the slot 'is set' bit
                    // This makes the code treat it as "null"
                    const ptr: *usize = @ptrCast(slot);
                    const mask = self.base.slotSetMask();
                    ptr.* &= ~mask;
                },
                .none => {},
            }
        }

        // Default read slot implementation.
        // pointer storage mode must return borrowed reference
        // static storage mode always returns a new reference
        pub inline fn readSlot(self: *Self, atom: *AtomBase, slot: *?*Object) py.Error!?*Object {
            switch (comptime storage_mode) {
                .pointer => {
                    if (slot.*) |value| {
                        return value;
                    }
                },
                .static => {
                    if (comptime !@hasDecl(impl, "readSlot")) {
                        @compileError("member impl must provide a readSlot if storage mode is static. Signature is `pub fn readSlot(self: *MemberBase, atom: *AtomBase, data: usize) py.Error!?*Object`");
                    }
                    const ptr: *usize = @ptrCast(slot);
                    const value = ptr.*;
                    if (value & self.base.slotSetMask() != 0) {
                        // Extract only the data allocated for this slot
                        const data = (value & self.base.slotDataMask()) >> self.base.info.offset;
                        return impl.readSlot(@ptrCast(self), atom, data);
                    }
                },
                .none => {},
            }
            return null;
        }

        // Default getattr implementation provides normal slot behavior
        // Returns new reference
        pub fn getattr(self: *Self, atom: *AtomBase) !*Object {
            if (atom.slotPtr(self.base.info.index)) |ptr| {
                if (try readSlot(@ptrCast(self), atom, ptr)) |v| {
                    if (comptime storage_mode == .pointer) {
                        return v.newref();
                    } else {
                        return v;
                    }
                }
                const default_handler = comptime if (@hasDecl(impl, "default")) impl.default else Self.default;
                const value = try default_handler(@ptrCast(self), atom);

                // We must track whether the write took ownership of the default value
                // becuse it is needed in notify create. If the writeSlot says it took ownership
                // of the value then we do not need to decref it. If an error occurs it gets decref'd
                var value_ownership: Ownership = .borrowed;
                defer if (value_ownership == .borrowed) value.decref();
                try self.validate(atom, py.None(), value);
                value_ownership = try writeSlot(@ptrCast(self), atom, ptr, value); // Default returns a new object
                try self.base.notifyCreate(atom, value);
                return value.newref();
            } else {
                // @branchHint(.cold);
                _ = py.attributeError("Member {s} has no slot", .{self.base.name.data()});
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

                if (try readSlot(@ptrCast(self), atom, ptr)) |old| {
                    defer if (storage_mode != .pointer) {
                        old.decref(); // Always decref if static
                    };
                    try self.validate(atom, old, value);
                    const r = try writeSlot(@ptrCast(self), atom, ptr, value.newref());
                    defer if (storage_mode == .pointer) {
                        old.decref(); // Only decref after write completes
                    };
                    defer if (r == .borrowed) value.decref();
                    try self.base.notifyUpdate(atom, old, value);
                } else {
                    try self.validate(atom, py.None(), value);
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
                if (try self.readSlot(atom, ptr)) |old| {
                    defer old.decref();
                    deleteSlot(@ptrCast(self), atom, ptr);
                    try self.base.notifyDelete(atom, old);
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

        // --------------------------------------------------------------------------
        // Type def
        // --------------------------------------------------------------------------
        pub fn init(self: *Self, args: *Tuple, kwargs: ?*Dict) c_int {
            if (comptime @hasDecl(impl, "default_mode")) {
                self.base.info.default_mode = impl.default_mode;
            }
            if (comptime @hasDecl(impl, "init")) {
                if (comptime @hasDecl(impl, "initDefault")) {
                    @compileError("initDefault is ignored when init is used");
                }
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
            if (comptime storage_mode != .pointer) {
                self.base.info.storage_mode = storage_mode;
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

const all_modules = .{
    @import("members/scalars.zig"),
    @import("members/enum.zig"),
    @import("members/instance.zig"),
    @import("members/typed.zig"),
    @import("members/tuple.zig"),
    @import("members/event.zig"),
};

const all_strings = .{
    "undefined", "type", "object", "name", "value", "oldvalue", "create", "update", "delete",
};

pub fn initModule(mod: *py.Module) !void {
    // Strings used to create the change dicts
    inline for (all_strings) |str| {
        @field(@This(), str ++ "_str") = try Str.internFromString(str);
        errdefer py.clear(@field(@This(), str ++ "_str"));
    }
    try MemberBase.initType();
    errdefer MemberBase.deinitType();
    try mod.addObjectRef("Member", @ptrCast(MemberBase.TypeObject.?));

    inline for (all_modules) |module| {
        try module.initModule(mod);
        errdefer module.deinitModule(mod);
    }
}

pub fn deinitModule(mod: *py.Module) void {
    MemberBase.deinitType();
    inline for (all_modules) |module| {
        module.deinitModule(mod);
    }
    inline for (all_strings) |str| {
        py.clear(&@field(@This(), str ++ "_str"));
    }
}
