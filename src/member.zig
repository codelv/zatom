const py = @import("py");
const std = @import("std");
const Type = py.Type;
const Metaclass = py.Metaclass;
const Object = py.Object;
const Str = py.Str;
const Int = py.Int;
const Dict = py.Dict;
const Tuple = py.Tuple;

// Thes strings are set at startup
pub var undefined_str: ?*Str = null;
pub var type_str: ?*Str = null;
pub var create_str: ?*Str = null;
pub var update_str: ?*Str = null;
pub var delete_str: ?*Str = null;
pub var name_str: ?*Str = null;
pub var object_str: ?*Str = null;
pub var key_str: ?*Str = null;
pub var value_str: ?*Str = null;
pub var oldvalue_str: ?*Str = null;
pub var item_str: ?*Str = null;
pub var property_str: ?*Str = null;

const Atom = @import("atom.zig").Atom;
const AtomMeta = @import("atom_meta.zig").AtomMeta;
const ObserverPool = @import("observer_pool.zig").ObserverPool;
const ChangeType = @import("observer_pool.zig").ChangeType;
const package_name = @import("api.zig").package_name;
const modes = @import("modes.zig");
const ValueMember = @import("members/scalars.zig").ValueMember;

const MAX_BITSIZE = @bitSizeOf(usize);
const MAX_OFFSET = @bitSizeOf(usize) - 1;

pub const StorageMode = enum(u2) {
    pointer = 0, // Object pointer
    static = 1, // Takes a fixed width of a slot
    none = 2, // Does not require any storage
};

pub const Ownership = enum(u1) { stolen = 0, borrowed = 1 };
pub const DefaultMode = enum(u2) { static = 0, func = 1, method = 2, method_name = 3 };
pub const ValidateMode = enum(u2) { default = 0, call_old_new = 1, call_name_old_new = 2, call_object_old_new = 3 };
pub const CoerceMode = enum(u1) { no = 0, yes = 1 };
pub const Observable = enum(u2) { no = 0, yes = 1, maybe = 2 };

pub const MemberInfo = packed struct {
    index: u16 = 0,
    width: u6 = 0, // bit size -1. A value of 0 means 1 one bit
    offset: u6 = 0, // starting bit position in slot
    storage_mode: StorageMode = .pointer,
    default_mode: DefaultMode = .static,
    validate_mode: ValidateMode = .default,
    // It is up to the member whether these is used or not
    optional: bool = false,
    coerce: bool = false,
    resolved: bool = false,
    typeid: u5 = 0,
    padding: u22 = 0,
};

// Base Member class
pub const MemberBase = extern struct {
    // Reference to the type. This is set in Fready
    pub var TypeObject: ?*Type = null;
    const Self = @This();

    base: Object,
    metadata: ?*Dict = null,
    default_context: ?*Object = null,
    validate_context: ?*Object = null,
    coercer_context: ?*Object = null,
    name: ?*Str = null,
    // The class or parent member which owns this member
    owner: ?*Object = null,
    info: MemberInfo,

    // Import the object protocol
    pub usingnamespace py.ObjectProtocol(@This());

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *const Object) bool {
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
        return self.name.?.newref();
    }

    pub fn set_name(self: *Self, value: *Object, _: ?*anyopaque) c_int {
        if (!Str.checkExact(value)) {
            return py.typeErrorObject(-1, "Member name must be a str", .{});
        }
        self.setName(@ptrCast(value));
        return 0;
    }

    pub fn get_index(self: *Self) ?*Object {
        if (self.info.storage_mode == .none) {
            return py.returnNone();
        }
        return @ptrCast(Int.newUnchecked(self.info.index));
    }

    pub fn set_index(self: *Self, value: ?*Object, _: ?*anyopaque) c_int {
        if (value) |v| {
            if (!Int.check(v)) {
                return py.typeErrorObject(-1, "Member index must be an int", .{});
            }
            self.info.index = Int.as(@ptrCast(v), u16) catch return -1;
            return 0;
        }
        return py.typeErrorObject(-1, "Member index cannot be deleted", .{});
    }

    pub fn get_bitsize(self: *Self) ?*Int {
        return Int.newUnchecked(@as(usize, self.info.width) + 1);
    }

    pub fn set_bitsize(self: *Self, value: ?*Object, _: ?*anyopaque) c_int {
        if (value) |v| {
            if (!Int.check(v)) {
                return py.typeErrorObject(-1, "Member bitsize must be an int", .{});
            }
            const n = Int.as(@ptrCast(v), usize) catch return -1;
            if (n == 0 or n > MAX_BITSIZE) {
                return py.typeErrorObject(-1, "Member bitsize must be between 1 and {}", .{MAX_BITSIZE});
            }
            self.info.width = @intCast(n - 1);
            return 0;
        }
        return py.typeErrorObject(-1, "Member bitsize cannot be deleted", .{});
    }

    pub fn get_offset(self: *Self) ?*Int {
        return Int.newUnchecked(self.info.offset);
    }

    pub fn set_offset(self: *Self, value: ?*Object, _: ?*anyopaque) c_int {
        if (value) |v| {
            if (!Int.check(v)) {
                return py.typeErrorObject(-1, "Member offset must be an int", .{});
            }
            const n = Int.as(@ptrCast(v), usize) catch return -1;
            if (n > MAX_OFFSET) {
                return py.typeErrorObject(-1, "Member offset must be between 0 and {}", .{MAX_OFFSET});
            }
            self.info.offset = @intCast(n);
            return 0;
        }
        return py.typeErrorObject(-1, "Member offset cannot be deleted", .{});
    }

    pub fn get_owner(self: *Self) ?*Object {
        return py.returnOptional(self.owner);
    }

    pub fn get_metadata(self: *Self) ?*Object {
        return py.returnOptional(self.metadata);
    }

    pub fn set_metadata(self: *Self, value: ?*Object, _: ?*anyopaque) c_int {
        if (value == null or value.?.isNone()) {
            py.clear(&self.metadata);
            return 0;
        } else if (Dict.check(value.?)) {
            py.xsetref(@ptrCast(&self.metadata), value.?.newref());
            return 0;
        }
        return py.typeErrorObject(-1, "Member metadata must be a dict or None", .{});
    }

    // --------------------------------------------------------------------------
    // Methods
    // --------------------------------------------------------------------------
    pub fn get_slot(self: *Self, atom: *Atom) ?*Object {
        if (!atom.typeCheckSelf()) {
            return py.typeErrorObject(null, "Invalid argument. Signature is get_slot(atom: Atom)", .{});
        }

        const ptr = atom.slotPtr(self) catch return null;
        switch (self.info.storage_mode) {
            .pointer => return py.returnOptional(ptr.*),
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

    pub fn set_slot(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n != 2 or !Atom.check(args[0])) {
            return py.attributeErrorObject(null, "Invalid arguments. Signature is set_slot(atom: Atom, value: object)", .{});
        }
        const atom: *Atom = @ptrCast(args[0]);
        const value = args[1];
        const ptr = atom.slotPtr(self) catch return null;
        switch (self.info.storage_mode) {
            .pointer => {
                py.xsetref(ptr, value.newref());
            },
            .static => {
                if (!Int.check(value)) {
                    return py.typeErrorObject(null, "set_slot requires an int", .{});
                }
                const data = Int.as(@ptrCast(value), usize) catch return null;
                const max_value = std.math.pow(usize, 2, self.info.width + 1);
                if (data < 0 or data > max_value) {
                    return py.typeErrorObject(null, "set_slot data out of range 0..{}", .{max_value});
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

    pub fn del_slot(self: *Self, atom: *Atom) ?*Object {
        if (!atom.typeCheckSelf()) {
            return py.typeErrorObject(null, "Invalid argument. Signature is del_slot(atom: Atom)", .{});
        }
        const ptr = atom.slotPtr(self) catch return null;
        switch (self.info.storage_mode) {
            .pointer => {
                py.clear(ptr);
            },
            .static => {
                const data_ptr: *usize = @ptrCast(ptr);
                data_ptr.* &= ~self.slotSetMask();
            },
            .none => unreachable,
        }
        return py.returnNone();
    }

    pub fn do_default_value(self: *Self, atom: *Atom) ?*Object {
        if (comptime @import("api.zig").debug_level.defaults) {
            if (@import("api.zig").debug_level.matches(self.name)) {
                py.print("Member.do_default_value(member: {s} {}, atom: {})\n", .{ self.name.?, self, atom }) catch return null;
            }
        }
        @setEvalBranchQuota(10000);
        inline for (all_modules) |mod| {
            if (comptime @hasDecl(mod, "all_members")) {
                inline for (mod.all_members) |M| {
                    if (self.info.typeid == M.typeid) {
                        return M.default(@ptrCast(self), atom) catch null;
                    }
                }
            }
        }
        if (self.info.typeid == 0) {
            return py.returnNone();
        }
        return py.systemErrorObject(null, "default cast failed: invalid member typeid {}", .{self.info.typeid});
    }

    pub fn set_default_value_mode(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n != 2 or !Int.check(args[0])) {
            return py.typeErrorObject(null, "Invalid arguments: Signature is set_default_value_mode(mode: int, context: object)", .{});
        }
        const context = args[1];
        const value = Int.as(@ptrCast(args[0]), u8) catch return null; // This does a range check
        if (value > @as(u8, @intFromEnum(modes.DefaultValue.MemberMethod_Object))) {
            return py.typeErrorObject(null, "Invalid DefaultValue mode {}", .{value});
        }
        const mode: modes.DefaultValue = @enumFromInt(value);
        switch (mode) {
            .CallObject => {
                if (!context.isCallable()) {
                    return py.typeErrorObject(null, "Context must be callable for mode {}", .{mode});
                }
                self.setDefaultContext(.func, context.newref());
            },
            .CallObject_Object => {
                if (!context.isCallable()) {
                    return py.typeErrorObject(null, "Context must be callable for mode {}", .{mode});
                }
                self.setDefaultContext(.method, context.newref());
            },
            .CallObject_ObjectName => {
                if (!context.isCallable()) {
                    return py.typeErrorObject(null, "Context must be callable for mode {}", .{mode});
                }
                self.setDefaultContext(.method_name, context.newref());
            },
            .MemberMethod_Object => {
                const member_method = self.getAttr(@ptrCast(context)) catch return null;
                if (!py.Method.check(member_method)) {
                    defer member_method.decref();
                    return py.typeErrorObject(null, "Context must the name of a member method for mode {}. Got '{s}'", .{ mode, context.typeName() });
                }
                self.setDefaultContext(.method, member_method);
            },
            else => {
                return py.typeErrorObject(null, "DefaultValue mode not yet supported {}", .{mode});
            },
        }
        return py.returnNone();
    }

    pub fn set_validate_mode(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n != 2 or !Int.check(args[0])) {
            return py.typeErrorObject(null, "Invalid arguments: Signature is set_validate_mode(mode: int, context: object)", .{});
        }
        const context = args[1];
        const value = Int.as(@ptrCast(args[0]), u8) catch return null; // This does a range check
        if (value > @as(u8, @intFromEnum(modes.Validate.MemberMethod_ObjectOldNew))) {
            return py.typeErrorObject(null, "Invalid Validate mode {}", .{value});
        }
        if (!(self.isInstance(@ptrCast(ValueMember.TypeObject.?)) catch return null)) {
            return py.typeErrorObject(null, "Validate mode can only be used on Value members. Use a dedicated member instead. Got '{s}'", .{self.typeName()});
        }
        const mode: modes.Validate = @enumFromInt(value);

        switch (mode) {
            .NoOp => {
                self.info.validate_mode = .default;
                py.xsetref(&self.validate_context, null);
            },
            .ObjectMethod_OldNew => {
                if (!context.isCallable()) {
                    return py.typeErrorObject(null, "Context must callable for mode {}. Got '{s}'", .{ mode, context.typeName() });
                }
                self.setValidateContext(.call_old_new, context.newref());
            },
            .ObjectMethod_NameOldNew => {
                if (!context.isCallable()) {
                    return py.typeErrorObject(null, "Context must callable for mode {}. Got '{s}'", .{ mode, context.typeName() });
                }
                self.setValidateContext(.call_name_old_new, context.newref());
            },
            .MemberMethod_ObjectOldNew => {
                const member_method = self.getAttr(@ptrCast(context)) catch return null;
                if (!py.Method.check(member_method)) {
                    defer member_method.decref();
                    return py.typeErrorObject(null, "Context must the name of a member method for mode {}. Got '{s}'", .{ mode, context.typeName() });
                }
                self.setValidateContext(.call_object_old_new, member_method);
            },
            else => {
                return py.typeErrorObject(null, "Validate mode not yet supported {}", .{mode});
            },
        }
        return py.returnNone();
    }

    pub fn has_observers(self: *Self) ?*Object {
        if (self.staticObservers()) |pool| {
            return py.returnBool(pool.hasTopic(self.name.?) catch return null);
        }
        return py.returnFalse();
    }

    pub fn has_observer(self: *Self, args: [*]*Object, n: isize) ?*Object {
        const msg = "Invalid arguments. Signature is has_observer(observer: str | Callable, change_types: int = 0xff)";
        var change_types: u8 = @intFromEnum(ChangeType.ANY);
        if (n < 1 or n > 2) {
            return py.typeErrorObject(null, msg, .{});
        }
        if (n == 2) {
            if (!Int.check(args[1])) {
                return py.typeErrorObject(null, msg, .{});
            }
            change_types = Int.as(@ptrCast(args[1]), u8) catch return null;
        }
        if (self.staticObservers()) |pool| {
            return py.returnBool(pool.hasObserver(self.name.?, args[0], change_types) catch return null);
        }
        return py.returnFalse();
    }

    pub fn add_static_observer(self: *Self, args: [*]*Object, n: isize) ?*Object {
        const msg = "Invalid arguments. Signature is add_static_observer(observer: str | Callable, change_types: int = 0xff)";
        if (n < 1 or n > 2) {
            return py.typeErrorObject(null, msg, .{});
        }
        const observer = args[0];
        if (!Str.check(observer) and !observer.isCallable()) {
            return py.typeErrorObject(null, msg, .{});
        }
        const change_types = blk: {
            if (n == 2) {
                const v = args[1];
                if (!Int.check(v)) {
                    return py.typeErrorObject(null, msg, .{});
                }
                break :blk Int.as(@ptrCast(v), u8) catch return null;
            }
            break :blk @intFromEnum(ChangeType.ANY);
        };

        if (self.staticAtomMeta()) |meta| {
            if (meta.staticObserverPool() catch return null) |pool| {
                pool.addObserver(py.allocator, self.name.?, observer, change_types) catch return null;
            }
        } else {
            return py.typeErrorObject(null, "Cannot add a static observer on a nested member", .{});
        }
        return py.returnNone();
    }

    pub fn remove_static_observer(self: *Self, observer: *Object) ?*Object {
        if (self.staticObservers()) |pool| {
            pool.removeObserver(py.allocator, self.name.?, observer) catch return null;
        }
        return py.returnNone();
    }

    pub fn clone(self: *Self) ?*Object {
        return @ptrCast(self.cloneOrError() catch null);
    }

    pub fn notify(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n < 1 or n > 2 or !Atom.check(args[0])) {
            return py.typeErrorObject(null, "Invalid arguments: Signature is notify(atom: Atom, change = None)", .{});
        }
        const atom: *Atom = @ptrCast(args[0]);
        if (n == 2) {
            atom.notifyInternal(self.name.?, .{args[1]}, @intFromEnum(ChangeType.ANY)) catch return null;
        } else {
            atom.notifyInternal(self.name.?, .{}, @intFromEnum(ChangeType.ANY)) catch return null;
        }
        return py.returnNone();
    }

    pub fn tag(self: *Self, args: *Tuple, kwargs: ?*Dict) ?*Object {
        if (args.sizeUnchecked() != 0) {
            return py.typeErrorObject(null, "tag() takes no positional arguments", .{});
        }
        if (kwargs) |kw| {
            if (self.metadata) |metadata| {
                metadata.update(@ptrCast(kw)) catch return null;
            } else {
                self.metadata = kw.copy() catch return null;
            }
            return @ptrCast(self.newref());
        }
        return py.typeErrorObject(null, "tag() requires keyword arguments", .{});
    }

    pub fn default_value_mode(self: *Self) ?*Object {
        const ctx = self.default_context orelse py.None();
        return @ptrCast(Tuple.packNewrefs(.{ py.None(), ctx }) catch null);
    }

    pub fn validate_mode(self: *Self) ?*Object {
        const ctx = self.validate_context orelse py.None();
        return @ptrCast(Tuple.packNewrefs(.{ py.None(), ctx }) catch null);
    }

    // --------------------------------------------------------------------------
    // Internal api
    // --------------------------------------------------------------------------
    // Borrows reference to name
    pub fn setName(self: *Self, name: *Str) void {
        py.xsetref(@ptrCast(&self.name), @ptrCast(name.newref()));
        Str.internInPlace(@ptrCast(&self.name.?));
    }

    // Borrows reference to pwmer
    pub fn setOwner(self: *Self, owner: ?*Object) void {
        if (owner) |o| {
            py.xsetref(&self.owner, o.newref());
        } else {
            py.clear(&self.owner);
        }
    }

    // Steals reference to context
    pub fn setDefaultContext(self: *Self, mode: DefaultMode, context: *Object) void {
        self.info.default_mode = mode;
        py.xsetref(&self.default_context, context);
    }

    // Steals reference to context
    pub fn setValidateContext(self: *Self, mode: ValidateMode, context: *Object) void {
        self.info.validate_mode = mode;
        py.xsetref(&self.validate_context, context);
    }

    // Steals reference to context
    pub fn setCoercerContext(self: *Self, mode: CoerceMode, context: *Object) void {
        self.info.coerce = mode == .yes;
        py.xsetref(&self.coercer_context, context);
    }

    pub inline fn validate(self: *Self, atom: *Atom, oldvalue: *Object, newvalue: *Object) py.Error!*Object {
        // Zig is able to inline validation of everything except the custom
        // containers that require coercion.
        @setEvalBranchQuota(10000);
        inline for (all_modules) |mod| {
            if (comptime @hasDecl(mod, "all_members")) {
                inline for (mod.all_members) |M| {
                    if (self.info.typeid == M.typeid) {
                        return M.validate(@ptrCast(self), atom, oldvalue, newvalue);
                    }
                }
            }
        }
        if (self.info.typeid == 0) {
            return newvalue.newref();
        }
        try py.systemError("validate cast failed: invalid member typeid {}", .{self.info.typeid});
        unreachable;
    }

    // Check if this member can observe the given topic
    // May return null if it cannot be known
    pub fn checkTopic(self: *Self, topic: *Str) py.Error!Observable {
        inline for (all_modules) |mod| {
            if (comptime @hasDecl(mod, "all_members")) {
                inline for (mod.all_members) |M| {
                    if (self.info.typeid == M.typeid) {
                        return M.checkTopic(@ptrCast(self), topic);
                    }
                }
            }
        }
        return .maybe;
    }

    // Helper function for validation failures
    pub inline fn validateFail(self: *const Self, atom: *Atom, value: *Object, expected: [:0]const u8) py.Error!void {
        // TODO: include name of "owner"
        return py.typeError("The '{s}' member on the '{s}' object must be of type '{s}'. Got object of type '{s}' instead", .{
            self.name.?.data(),
            atom.typeName(),
            expected,
            value.typeName(),
        });
    }

    pub fn validateTypeOrTupleOfTypes(self: *const Self, kind: *Object) py.Error!void {
        if (Type.check(kind)) {
            return;
        } else if (Tuple.checkExact(kind)) {
            const kinds: *Tuple = @ptrCast(kind);
            const n: usize = @intCast(kinds.sizeUnchecked());
            if (n == 0) {
                return py.typeError("{s} kind must be a type or tuple of types. Got an empty tuple", .{self.typeName()});
            }
            for (0..n) |i| {
                const obj = kinds.getUnsafe(i).?;
                if (!Type.check(obj)) {
                    return py.typeError("{s} kind must be a type or tuple of types. Got a tuple with '{s}'", .{
                        self.typeName(),
                        obj.typeName(),
                    });
                }
            }
            return;
        } else {
            return py.typeError("{s} kind must be a type or tuple of types. Got an empty tuple", .{self.typeName()});
        }
    }

    pub fn bindValidatorMember(self: *Self, item_member: *MemberBase, name: *Str) !void {
        if (!item_member.typeCheckSelf() or !name.typeCheckSelf()) {
            return py.systemError("init validator error", .{});
        }
        // Set the name and owner
        if (item_member.owner != null) {
            return py.typeError("Cannot reuse a member bound to another member", .{});
        }
        item_member.setName(name);
        item_member.setOwner(@ptrCast(self));
    }

    pub fn unbindValidatorMember(self: *Self, item_member: *MemberBase) !void {
        if (!item_member.typeCheckSelf()) {
            return py.systemError("init validator error", .{});
        }
        if (item_member.owner != self) {
            return py.systemError("cannot unbind a member owned someone else", .{});
        }
        py.clear(&item_member.owner);
    }

    // Get the pointer to the class on which this was defined
    // if this is an unowned member, or nested validator, return null
    pub fn staticAtomMeta(self: *Self) ?*AtomMeta {
        if (self.owner) |owner| {
            if (AtomMeta.check(owner)) {
                return @ptrCast(owner);
            }
        }
        return null;
    }

    // Only members bound to an atom can have observers
    pub fn staticObservers(self: *Self) ?*ObserverPool {
        if (self.staticAtomMeta()) |meta| {
            return meta.static_observers;
        }
        return null;
    }

    pub fn shouldNotify(self: *Self, atom: *Atom, change_type: ChangeType) bool {
        return (!atom.info.notifications_disabled and atom.hasAnyObservers(self.name.?, change_type) catch unreachable);
    }

    pub fn notifyChange(self: *Self, atom: *Atom, change: *Dict, change_type: ChangeType) !void {
        try atom.notifyInternal(self.name.?, .{change}, @intFromEnum(change_type));
    }

    pub fn notifyCreate(self: *Self, atom: *Atom, newvalue: *Object) !void {
        if (self.shouldNotify(atom, .CREATE)) {
            var change: *Dict = try Dict.new();
            defer change.decref();
            try change.set(@ptrCast(type_str.?), @ptrCast(create_str.?));
            try change.set(@ptrCast(object_str.?), @ptrCast(atom));
            try change.set(@ptrCast(name_str.?), @ptrCast(self.name.?));
            try change.set(@ptrCast(value_str.?), newvalue);
            return self.notifyChange(atom, change, .CREATE);
        }
    }

    pub fn notifyUpdate(self: *Self, atom: *Atom, oldvalue: *Object, newvalue: *Object) !void {
        if (oldvalue != newvalue and self.shouldNotify(atom, .UPDATE)) {
            var change: *Dict = try Dict.new();
            defer change.decref();
            try change.set(@ptrCast(type_str.?), @ptrCast(update_str.?));
            try change.set(@ptrCast(object_str.?), @ptrCast(atom));
            try change.set(@ptrCast(name_str.?), @ptrCast(self.name.?));
            try change.set(@ptrCast(oldvalue_str.?), oldvalue);
            try change.set(@ptrCast(value_str.?), newvalue);
            return self.notifyChange(atom, change, .UPDATE);
        }
    }

    pub fn notifyDelete(self: *Self, atom: *Atom, oldvalue: *Object) !void {
        if (self.shouldNotify(atom, .DELETE)) {
            var change: *Dict = try Dict.new();
            defer change.decref();
            try change.set(@ptrCast(type_str.?), @ptrCast(delete_str.?));
            try change.set(@ptrCast(object_str.?), @ptrCast(atom));
            try change.set(@ptrCast(name_str.?), @ptrCast(self.name.?));
            try change.set(@ptrCast(value_str.?), oldvalue);
            return self.notifyChange(atom, change, .DELETE);
        }
    }

    // Returns new reference
    pub fn cloneOrError(self: *Self) !*Self {
        if (comptime @import("api.zig").debug_level.clones) {
            try py.print("Member.clone('{s}')\n", .{self.name.?});
        }
        const cls = self.typeref();
        const result: *Self = @ptrCast(try cls.genericNew(null, null));
        errdefer result.decref();
        result.info = self.info;
        if (self.name) |name| {
            result.name = name.newref();
        } else {
            result.name = undefined_str.?.newref();
        }
        if (self.owner) |o| {
            result.owner = o.newref();
        }
        if (self.metadata) |metadata| {
            result.metadata = try metadata.copy();
        }
        inline for (.{ "default", "validate", "coercer" }) |name| {
            const field_name = name ++ "_context";
            if (@field(self, field_name)) |context| {
                @field(result, field_name) = context.newref();
            }
        }
        return result;
    }

    // Mask for slot's data bits
    pub inline fn slotDataMask(self: Self) usize {
        const bitwidth = self.info.width + 1;
        const mask: usize = (@as(usize, 1) << bitwidth) - 1;
        return mask << self.info.offset;
    }

    // Mask for slot's 'is set' bit
    pub inline fn slotSetMask(self: Self) usize {
        const bitwidth = self.info.width + 1;
        const pos: u6 = self.info.offset + bitwidth;
        return @as(usize, @as(usize, 1) << pos);
    }

    pub fn hasSameMemoryLayout(self: *Self, other: *Self) bool {
        return (self.info.storage_mode == other.info.storage_mode and self.info.width == other.info.width);
    }

    // Generic implementation to generate the default value
    // The impl can override per mode as needed.
    // Returns new reference
    pub inline fn default(self: *MemberBase, comptime impl: type, atom: *Atom) py.Error!*Object {
        switch (self.info.default_mode) {
            .static => {
                if (comptime @hasDecl(impl, "defaultStatic")) {
                    return impl.defaultStatic(self, atom);
                }
                return py.returnOptional(self.default_context);
            },
            .func => {
                if (comptime @hasDecl(impl, "defaultFunc")) {
                    return impl.defaultFunc(self, atom);
                }
                if (self.default_context) |callable| {
                    return callable.callArgs(.{});
                }
            },
            .method => {
                if (comptime @hasDecl(impl, "defaultMethod")) {
                    return impl.defaultMethod(self, atom);
                }
                if (self.default_context) |callable| {
                    return callable.callArgs(.{atom});
                }
            },
            .method_name => {
                if (comptime @hasDecl(impl, "defaultMethodName")) {
                    return impl.defaultMethodName(self, atom);
                }
                if (self.default_context) |callable| {
                    return callable.callArgs(.{ atom, self.name.? });
                }
            },
        }
        try py.systemError("default context missing", .{});
        unreachable;
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
        if (comptime @import("api.zig").debug_level.clears) {
            py.print("Member.clear(name: {?s}, owner: {?s})\n", .{ self.name, self.owner }) catch return -1;
        }
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

    // Check if object is an atom_meta
    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        if (comptime @import("api.zig").debug_level.traverse) {
            if (@import("api.zig").debug_level.matches(self.name)) {
                py.print("Member.traverse(name: {?s}, owner: {?s}, meta: {?s}, default_context: {?s}, validate_context={?s}, coercer_context={?s})\n", .{
                    self.name,
                    self.owner,
                    self.metadata,
                    self.default_context,
                    self.validate_context,
                    self.coercer_context,
                }) catch return -1;
            }
        }
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
        .{ .name = "validate_mode", .get = @ptrCast(&validate_mode), .set = null, .doc = "Get the member's validate mode and context" },
        .{ .name = "default_value_mode", .get = @ptrCast(&default_value_mode), .set = null, .doc = "Get the member's default value mode and context" },
        .{}, // sentinel
    };

    const methods = [_:py.MethodDef{}]py.MethodDef{
        .{ .ml_name = "get_slot", .ml_meth = @constCast(@ptrCast(&get_slot)), .ml_flags = py.c.METH_O, .ml_doc = "Get slot value directly" },
        .{ .ml_name = "set_slot", .ml_meth = @constCast(@ptrCast(&set_slot)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Set slot value directly" },
        .{ .ml_name = "del_slot", .ml_meth = @constCast(@ptrCast(&del_slot)), .ml_flags = py.c.METH_O, .ml_doc = "Del slot value directly" },
        .{ .ml_name = "notify", .ml_meth = @constCast(@ptrCast(&notify)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Notify the observers for the given member and atom." },
        .{ .ml_name = "has_observers", .ml_meth = @constCast(@ptrCast(&has_observers)), .ml_flags = py.c.METH_NOARGS, .ml_doc = "Get whether or not this member has observers." },
        .{ .ml_name = "has_observer", .ml_meth = @constCast(@ptrCast(&has_observer)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Get whether or not the member already has the given observer." },
        .{ .ml_name = "add_static_observer", .ml_meth = @constCast(@ptrCast(&add_static_observer)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Add the name of a method to call on all atoms when the member changes." },
        .{ .ml_name = "remove_static_observer", .ml_meth = @constCast(@ptrCast(&remove_static_observer)), .ml_flags = py.c.METH_O, .ml_doc = "Remove the name of a method to call on all atoms when the member changes." },
        .{ .ml_name = "do_default_value", .ml_meth = @constCast(@ptrCast(&do_default_value)), .ml_flags = py.c.METH_O, .ml_doc = "Retrieve the default value." },
        .{ .ml_name = "set_default_value_mode", .ml_meth = @constCast(@ptrCast(&set_default_value_mode)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Set the default value mode." },
        .{ .ml_name = "set_validate_mode", .ml_meth = @constCast(@ptrCast(&set_validate_mode)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Set the validate mode." },
        .{ .ml_name = "tag", .ml_meth = @constCast(@ptrCast(&tag)), .ml_flags = py.c.METH_VARARGS | py.c.METH_KEYWORDS, .ml_doc = "Tag the member with metadata" },
        .{ .ml_name = "clone", .ml_meth = @constCast(@ptrCast(&clone)), .ml_flags = py.c.METH_NOARGS, .ml_doc = "Clone the member" },
    };

    const type_slots = [_:py.TypeSlot{}]py.TypeSlot{
        .{ .slot = py.c.Py_tp_new, .pfunc = @constCast(@ptrCast(&new)) },
        .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
        .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
        .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
        .{ .slot = py.c.Py_tp_methods, .pfunc = @constCast(@ptrCast(&methods)) },
        .{ .slot = py.c.Py_tp_getset, .pfunc = @constCast(@ptrCast(&getset)) },
        //.{ .slot = py.c.Py_tp_descr_get, .pfunc = @constCast(@ptrCast(&__get__)) },
        //.{ .slot = py.c.Py_tp_descr_set, .pfunc = @constCast(@ptrCast(&__set__)) },
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
pub fn Member(comptime type_name: [:0]const u8, comptime id: u5, comptime impl: type) type {
    return extern struct {
        pub var TypeObject: ?*Type = null;
        pub const TypeName = type_name;
        pub const Impl = impl;
        pub const storage_mode: StorageMode = if (@hasDecl(impl, "storage_mode")) impl.storage_mode else .pointer;
        pub const typeid = id;
        const Self = @This();

        base: MemberBase,

        // Import the object protocol
        pub usingnamespace py.ObjectProtocol(@This());

        // Type check the given object. This assumes the module was initialized
        pub fn check(obj: *Object) bool {
            return obj.typeCheck(TypeObject.?);
        }

        // Check if the topic is valid for observation
        pub fn checkTopic(self: *Self, topic: *Str) py.Error!Observable {
            if (comptime @hasDecl(impl, "checkTopic")) {
                return impl.checkTopic(@ptrCast(self), topic);
            }
            if (comptime @hasDecl(impl, "observable")) {
                return impl.observable;
            }
            return .no;
        }

        // --------------------------------------------------------------------------
        // Custom member api
        // --------------------------------------------------------------------------
        // Returns new reference
        pub inline fn default(self: *Self, atom: *Atom) py.Error!*Object {
            if (comptime @import("api.zig").debug_level.defaults) {
                if (@import("api.zig").debug_level.matches(self.base.name)) {
                    try py.print("{s}.default(name: {?s}, index: {}, storage_mode: {s}, default_mode: {s}, atom: {})\n", .{ type_name, self.base.name, self.base.info.index, @tagName(storage_mode), @tagName(self.base.info.default_mode), atom });
                }
            }
            if (comptime @hasDecl(impl, "default")) {
                return impl.default(@ptrCast(self), atom);
            }
            return self.base.default(impl, atom);
        }

        // Default getattr implementation provides normal slot behavior
        // Returns new reference
        pub inline fn getattr(self: *Self, atom: *Atom) py.Error!*Object {
            if (comptime @hasDecl(impl, "getattr")) {
                return impl.getattr(@ptrCast(self), atom);
            }
            const ptr = try atom.slotPtr(@ptrCast(self));
            if (try readSlot(@ptrCast(self), atom, ptr)) |v| {
                return switch (comptime storage_mode) {
                    .pointer => v.newref(),
                    .static => v, // readSlot in static mode is always already a newref
                    .none => unreachable,
                };
            }
            const default_value = try self.default(atom);
            defer default_value.decref();

            // We must track whether the write took ownership of the default value
            // becuse it is needed in notify create. If the writeSlot says it took ownership
            // of the value then we do not need to decref it. If an error occurs it gets decref'd
            const value = try self.validate(atom, py.None(), default_value);
            var value_ownership: Ownership = .borrowed;
            defer if (value_ownership == .borrowed) value.decref();
            value_ownership = try writeSlot(@ptrCast(self), atom, ptr, value); // Default returns a new object
            try self.base.notifyCreate(atom, value);
            return value.newref();
        }

        // Default read slot implementation.
        // pointer storage mode must return borrowed reference
        // static storage mode always returns a new reference
        pub inline fn readSlot(self: *Self, atom: *Atom, slot: *?*Object) py.Error!?*Object {
            if (comptime @import("api.zig").debug_level.reads) {
                if (@import("api.zig").debug_level.matches(self.base.name)) {
                    try py.print("{s}.readSlot(name: {?s}, index: {}, storage_mode: {s}, atom: {})\n", .{ type_name, self.base.name, self.base.info.index, @tagName(storage_mode), atom });
                }
            }
            switch (comptime storage_mode) {
                .pointer => {
                    if (comptime @hasDecl(impl, "readSlotPointer")) {
                        return impl.readSlotPointer(@ptrCast(self), atom, slot);
                    }
                    if (slot.*) |value| {
                        return value;
                    }
                },
                .static => {
                    if (comptime !@hasDecl(impl, "readSlotStatic")) {
                        @compileError("member impl must provide a readSlotStatic if storage mode is static. Signature is `pub fn readSlotStatic(self: *MemberBase, atom: *Atom, data: usize) py.Error!?*Object`");
                    }
                    const ptr: *usize = @ptrCast(slot);
                    const value = ptr.*;
                    if (value & self.base.slotSetMask() != 0) {
                        // Extract only the data allocated for this slot
                        const data = (value & self.base.slotDataMask()) >> self.base.info.offset;
                        return impl.readSlotStatic(@ptrCast(self), atom, data);
                    }
                },
                .none => {},
            }
            return null;
        }

        // Default setattr implementation provides normal slot behavior
        pub inline fn setattr(self: *Self, atom: *Atom, newvalue: *Object) py.Error!void {
            if (comptime @hasDecl(impl, "setattr")) {
                return impl.setattr(@ptrCast(self), atom, newvalue);
            }
            if (atom.info.is_frozen) {
                // @branchHint(.unlikely);
                return py.attributeError("Can't set attribute of frozen Atom", .{});
            }
            const ptr = try atom.slotPtr(@ptrCast(self));

            // If writeSlot does not take Ownership of the value then
            // we need to decref the validated/coerced result
            var value_ownership: Ownership = .borrowed;
            if (try readSlot(@ptrCast(self), atom, ptr)) |old| {
                defer if (storage_mode == .static) {
                    old.decref(); // Always decref if static
                };
                const value = try self.validate(atom, old, newvalue);
                defer if (value_ownership == .borrowed) value.decref();
                value_ownership = try writeSlot(@ptrCast(self), atom, ptr, value);
                defer if (storage_mode == .pointer) {
                    old.decref(); // Only decref after write completes
                };
                try self.base.notifyUpdate(atom, old, value);
            } else {
                const value = try self.validate(atom, py.None(), newvalue);
                defer if (value_ownership == .borrowed) value.decref();
                value_ownership = try writeSlot(@ptrCast(self), atom, ptr, value);
                try self.base.notifyCreate(atom, value);
            }
            return; // Ok
        }

        // Default write slot implementation. It does not need to worry about discarding the old value but must
        // return whether it stole a reference to value or borrowed it so the caller can know how to handle it.
        pub inline fn writeSlot(self: *Self, atom: *Atom, slot: *?*Object, value: *Object) py.Error!Ownership {
            if (comptime @import("api.zig").debug_level.writes) {
                if (@import("api.zig").debug_level.matches(self.base.name)) {
                    try py.print("{s}.writeSlot(name: {?s}, index: {}, storage_mode: {s}, atom: {}, value: {?s})\n", .{ type_name, self.base.name, self.base.info.index, @tagName(storage_mode), atom, value });
                }
            }
            switch (comptime storage_mode) {
                .pointer => {
                    if (comptime @hasDecl(impl, "writeSlotPointer")) {
                        return impl.writeSlotPointer(@ptrCast(self), atom, slot);
                    }
                    slot.* = value;
                    return .stolen;
                },
                .static => {
                    if (comptime !@hasDecl(impl, "writeSlotStatic")) {
                        @compileError("member impl must provide a writeSlotStatic function if storage mode is static. Signature is `pub fn writeSlotStatic(self: *MemberBase, atom: *Atom, value: *Object) py.Error!usize`");
                    }
                    const ptr: *usize = @ptrCast(slot);
                    const data_mask = self.base.slotDataMask();
                    const set_mask = self.base.slotSetMask();
                    const data = try impl.writeSlotStatic(@ptrCast(self), atom, value);
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

        // Default delattr implementation
        pub inline fn delattr(self: *Self, atom: *Atom) py.Error!void {
            if (comptime @hasDecl(impl, "delattr")) {
                return impl.delattr(@ptrCast(self), atom);
            }
            if (atom.info.is_frozen) {
                // @branchHint(.unlikely);
                return py.attributeError("Can't delete attribute of frozen Atom", .{});
            }
            const ptr = try atom.slotPtr(@ptrCast(self));
            if (try self.readSlot(atom, ptr)) |old| {
                defer old.decref();
                deleteSlot(@ptrCast(self), atom, ptr);
                try self.base.notifyDelete(atom, old);
            }
        }

        // Default delete slot implementation. It does not need to worry about discarding the old value
        pub inline fn deleteSlot(self: *Self, atom: *Atom, slot: *?*Object) void {
            if (comptime @import("api.zig").debug_level.deletes) {
                if (@import("api.zig").debug_level.matches(self.base.name)) {
                    py.print("{s}.deleteSlot(name: {?s}, index: {}, storage_mode: {s}, atom: {})\n", .{ type_name, self.base.name, self.base.info.index, @tagName(storage_mode), atom }) catch {};
                }
            }
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

        pub fn validateGeneric(self: *MemberBase, atom: *Atom, oldvalue: *Object, newvalue: *Object) py.Error!*Object {
            return validate(@ptrCast(self), atom, oldvalue, newvalue);
        }

        pub inline fn validate(self: *Self, atom: *Atom, oldvalue: *Object, newvalue: *Object) py.Error!*Object {
            if (comptime @hasDecl(impl, "coerce") and @hasDecl(impl, "validate")) {
                @compileError("impl cannot have both coerce and validate");
            } else if (comptime @hasDecl(impl, "coerce")) {
                return impl.coerce(@ptrCast(self), atom, oldvalue, newvalue);
            } else if (comptime @hasDecl(impl, "validate")) {
                return impl.validate(@ptrCast(self), atom, oldvalue, newvalue);
            } else {
                return newvalue.newref();
            }
        }

        // --------------------------------------------------------------------------
        // Type def
        // --------------------------------------------------------------------------
        pub fn new(cls: *Type, args: *Tuple, kwargs: ?*Dict) ?*Self {
            return newOrError(cls, args, kwargs) catch null;
        }

        pub fn newOrError(cls: *Type, args: *Tuple, kwargs: ?*Dict) !*Self {
            const self: *Self = @ptrCast(try cls.genericNew(args, kwargs));
            self.base.name = undefined_str.?.newref();
            self.base.info.typeid = typeid;
            self.base.info.storage_mode = storage_mode;
            if (comptime storage_mode == .static and @hasDecl(impl, "default_bitsize")) {
                self.base.info.width = impl.default_bitsize - 1;
            }
            return self;
        }

        pub fn init(self: *Self, args: *Tuple, kwargs: ?*Dict) c_int {
            self.initOrError(args, kwargs) catch return -1;
            return 0;
        }

        pub inline fn initOrError(self: *Self, args: *Tuple, kwargs: ?*Dict) !void {
            if (comptime @hasDecl(impl, "init")) {
                if (comptime @hasDecl(impl, "initDefault")) {
                    @compileError("initDefault is ignored when init is used");
                }
                return impl.init(@ptrCast(self), args, kwargs);
            }

            const kwlist = [_:null][*c]const u8{
                "default",
                "factory",
            };
            var default_context: ?*Object = null;
            var default_factory: ?*Object = null;
            try py.parseTupleAndKeywords(args, kwargs, "|OO", @ptrCast(&kwlist), .{ &default_context, &default_factory });

            if (py.notNone(default_context) and py.notNone(default_factory)) {
                try py.typeError("Cannot use both a default and a factory function", .{});
            }

            if (py.notNone(default_factory)) {
                if (!default_factory.?.isCallable()) {
                    try py.typeError("factory must be a callable that returns the default value", .{});
                }
                self.base.setDefaultContext(.func, default_factory.?.newref());
            } else if (py.notNone(default_context)) {
                self.base.setDefaultContext(.static, default_context.?.newref());
            } else if (comptime @hasDecl(impl, "initDefault")) {
                self.base.setDefaultContext(.static, try impl.initDefault());
            }
        }

        pub fn __get__(self: *Self, cls: ?*Atom, _: ?*Object) ?*Object {
            if (cls) |atom| {
                if (!atom.typeCheckSelf()) {
                    return py.typeErrorObject(null, "Members can only be used on Atom objects", .{});
                }
                const value = self.getattr(atom) catch null;
                if (comptime @import("api.zig").debug_level.gets) {
                    if (@import("api.zig").debug_level.matches(self.base.name)) {
                        py.print("{s}.get(name: {?s}, index: {}, storage_mode: {s}, default_mode: {s}, atom: {}, result={?s})\n", .{ type_name, self.base.name, self.base.info.index, @tagName(storage_mode), @tagName(self.base.info.default_mode), atom, value }) catch return null;
                    }
                }
                return value;
            }
            return @ptrCast(self.newref());
        }

        pub fn __set__(self: *Self, atom: *Atom, value: ?*Object) c_int {
            if (!atom.typeCheckSelf()) {
                return py.typeErrorObject(-1, "Members can only be used on Atom objects", .{});
            }
            if (comptime @import("api.zig").debug_level.sets) {
                if (@import("api.zig").debug_level.matches(self.base.name)) {
                    py.print("{s}.set(name: {?s}, index: {}, storage_mode: {s}, default_mode: {s}, atom: {}, value={?s})\n", .{ type_name, self.base.name, self.base.info.index, @tagName(storage_mode), @tagName(self.base.info.default_mode), atom, value }) catch return -1;
                }
            }
            if (value) |v| {
                self.setattr(atom, v) catch return -1;
            } else {
                self.delattr(atom) catch return -1;
            }
            return 0;
        }

        const extra_type_slots = if (@hasDecl(impl, "type_slots")) impl.type_slots else [_]py.TypeSlot{};
        const type_slots = [_]py.TypeSlot{
            .{ .slot = py.c.Py_tp_new, .pfunc = @constCast(@ptrCast(&new)) },
            .{ .slot = py.c.Py_tp_init, .pfunc = @constCast(@ptrCast(&init)) },
            .{ .slot = py.c.Py_tp_descr_get, .pfunc = @constCast(@ptrCast(&__get__)) },
            .{ .slot = py.c.Py_tp_descr_set, .pfunc = @constCast(@ptrCast(&__set__)) },
        } ++ extra_type_slots ++ [_]py.TypeSlot{.{}};

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
    @import("members/list.zig"),
    @import("members/dict.zig"),
    @import("members/typed.zig"),
    @import("members/tuple.zig"),
    @import("members/set.zig"),
    @import("members/event.zig"),
    @import("members/coerced.zig"),
    @import("members/property.zig"),
};

const all_strings = .{ "undefined", "type", "object", "name", "value", "oldvalue", "key", "create", "update", "delete", "item", "property" };
//
//

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
