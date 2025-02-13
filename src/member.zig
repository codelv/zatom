const py = @import("py.zig");
const Type = py.Type;
const Metaclass = py.Metaclass;
const Object = py.Object;
const Str = py.Str;
const Int = py.Int;
const Dict = py.Dict;
const Tuple = py.Tuple;

// This is set at startup
var default_name_str: ?*Str = null;

const AtomBase = @import("atom.zig").AtomBase;
const package_name = @import("api.zig").package_name;
const scalars = @import("members/scalars.zig");


pub const StorageMode = enum(u2) {
    slot, // Takes a full slot
    bit, // Takes a single bit of a slot
    none, // Does not require any storage
};

pub const DefaultMode = enum(u1) {
    static,
    call
};

pub const MemberInfo = packed struct {
    index: u16,
    bit: u5, // bool bitfield
    storage_mode: StorageMode,
    default_mode: DefaultMode,
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
            _ = py.typeError("Member name must be a str");
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
                _ = py.typeError("Member index must be an int");
                return -1;
            }
            self.info.index = Int.as(@ptrCast(v), u16) catch return -1;
        }
        _ = py.typeError("Member index cannot be deleted");
        return -1;
    }

    pub fn get_bit(self: *Self) ?*Int {
        return Int.fromNumberUnchecked(self.info.bit);
    }

    pub fn set_bit(self: *Self, value: ?*Object, _: ?*anyopaque) c_int {
        if (value) |v| {
            if (!Int.check(v)) {
                _ = py.typeError("Member bit must be an int");
                return -1;
            }
            self.info.bit = Int.as(@ptrCast(v), u5) catch return -1;
        }
        _ = py.typeError("Member bit cannot be deleted");
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
                _ = py.typeError("Member metadata must be a dict");
                return -1;
            }
        }
        py.xsetref(@ptrCast(&self.metadata), value);
        return 0;
    }

    pub fn get_slot(self: *Self, atom: *AtomBase) ?*Object {
        if (!atom.typeCheckSelf()) {
            return py.typeError("Atom");
        }
        if (atom.slotPtr(self.info.index)) |ptr| {
            return ptr.*;
        }
        return py.attributeError("Member has no slot");
    }

    pub fn set_slot(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n != 2) {
            return py.attributeError("set_slot takes 2 arguments");
        }
        const atom: *AtomBase = @ptrCast(args[0]);
        if (!atom.typeCheckSelf()) {
            return py.typeError("Atom");
        }
        if (atom.slotPtr(self.info.index)) |ptr| {
            ptr.* = args[1];
            return py.returnNone();
        }
        return py.attributeError("Member has no slot");
    }

    pub fn del_slot(self: *Self, atom: *AtomBase) ?*Object {
        if (!atom.typeCheckSelf()) {
            return py.typeError("Atom");
        }
        if (atom.slotPtr(self.info.index)) |ptr| {
            ptr.* = null;
            return py.returnNone();
        }
        return py.attributeError("Member has no slot");
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

        if (self.default_context) | context | {
            result.default_context = context.newref();
        }
        errdefer if (result.default_context) |context| context.decref();

        if (self.validate_context) | context | {
            result.validate_context = context.newref();
        }
        errdefer if (result.validate_context) |context| context.decref();
        if (self.coercer_context) | context | {
            result.coercer_context = context.newref();
        }
        errdefer if (result.coercer_context) |context| context.decref();

        return @ptrCast(result);
    }

    pub fn dealloc(self: *Self) void {
        self.gcUntrack();
        _ = self.clear();
        self.typeref().impl.tp_free.?(@ptrCast(self));
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


pub fn no_default() !?*Object {
    return null;
}

// Create a new member subclass from the given spec
pub const MemberSpec = struct {
    name: [:0]const u8,
    storage_mode: StorageMode = StorageMode.slot,

    // These all must return a new reference
    default: ?*const fn (self: *MemberBase, atom: *AtomBase) py.Error!*Object = null,
    getattr: ?*const fn (self: *MemberBase, atom: *AtomBase) py.Error!*Object = null,
    coercer: ?*const fn (self: *MemberBase, atom: *AtomBase, value: *Object) py.Error!*Object = null,

    // Set and return a PyError if set/delete fails
    setattr: ?*const fn (self: *MemberBase, atom: *AtomBase, value: *Object) py.Error!void = null,
    delattr: ?*const fn (self: *MemberBase, atom: *AtomBase) py.Error!void = null,

    // init
    init: ?*const fn (self: *MemberBase, args: *Tuple, kwargs: ?*Dict) py.Error!void = null,

    // Set and return a PyError if validation fails
    validate: ?*const fn (self: *MemberBase, atom: *AtomBase, old: *Object, new: *Object) py.Error!void = null,
    check_validate_context: ?*const fn (self: *MemberBase, context: ?*Object) py.Error!void = null,
    check_coercer_context: ?*const fn (self: *MemberBase, context: ?*Object) py.Error!void = null,

    // Must return a new reference
    default_factory: *const fn() py.Error!?*Object = no_default,
};

// Create a member subclass with the given mode
pub fn Member(comptime spec: MemberSpec) type {
    return extern struct {
        pub var TypeObject: ?*Type = null;
        pub const BaseType = MemberBase;
        pub const Spec = spec;
        const Self = @This();

        base: BaseType,

        // Import the object protocol
        pub usingnamespace py.ObjectProtocol(@This());

        // Type check the given object. This assumes the module was initialized
        pub fn check(obj: *Object) bool {
            return obj.typeCheck(TypeObject.?);
        }

        pub fn init(self: *Self, args: *Tuple, kwargs: ?*Dict) c_int {
            self.base.info.storage_mode = spec.storage_mode;
            if (comptime spec.init) |initalizer| {
                initalizer(@ptrCast(self), args, kwargs) catch return -1;
            } else {
                const kwlist = [_:null][*c]const u8{
                    "default",
                    "factory",
                };
                var default_context: ?*Object = null;
                var default_factory: ?*Object = null;
                py.parseTupleAndKeywords(args, kwargs, "|OO", @ptrCast(&kwlist), .{&default_context, &default_factory}) catch return -1;

                if (default_context) |context| {
                    self.base.default_context = context.newref();
                } else if (spec.default_factory()) |context| {
                    self.base.default_context = context;
                } else |_| {
                    return -1;
                }
            }
            return 0;
        }

        pub fn __get__(self: *Self, cls: ?*AtomBase, _: ?*Object) ?*Object {
            if (cls) |atom| {
                if (!atom.typeCheckSelf()) {
                    return py.typeError("Members can only be used on Atom objects");
                }
                const handler = comptime if (spec.getattr) |f| f else Self.getattr;
                return handler(@ptrCast(self), atom) catch null;
            }
            return @ptrCast(self.newref());
        }

        pub fn __set__(self: *Self, atom: *AtomBase, value: ?*Object) c_int {
            if (!atom.typeCheckSelf()) {
                _ = py.typeError("Atom");
                return -1;
            }
            if (value) |v| {
                const handler = comptime if (spec.setattr) |f| f else Self.setattr;
                handler(@ptrCast(self), atom, v) catch return -1;
            } else {
                const handler = comptime if (spec.delattr) |f| f else Self.delattr;
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
                        _ = py.systemError("default context missing");
                        return error.PyError;
                    }
                },
            }
        }

        // Default getattr implementation provides normal slot behavior
        // Returns new reference
        pub fn getattr(self: *Self, atom: *AtomBase) !*Object {
            if (atom.slotPtr(self.base.info.index)) |ptr| {
                if (ptr.*) |value| {
                    return value.newref();
                }
                const old = py.None();
                defer old.decref(); // TODO: None does not need decref on 3.12+
                const default_handler = comptime if (spec.default) |f| f else Self.default;
                const value = try default_handler(@ptrCast(self), atom);
                {
                    // Only decref default value just created if validate fails, otherwise
                    // we take ownership
                    errdefer value.decref();
                    try self.validate(atom, old, value);
                }
                ptr.* = value; // Default returns a new object
                try self.base.notifyCreate(atom, value);
                return value.newref(); // Ok
            } else {
                // @branchHint(.cold);
                _ = py.attributeError("Member has no slot");
                return error.PyError;
            }
        }

        // Default setattr implementation provides normal slot behavior
        pub fn setattr(self: *Self, atom: *AtomBase, value: *Object) !void {
            if (atom.slotPtr(self.base.info.index)) |ptr| {
                if (atom.info.is_frozen) {
                    // @branchHint(.unlikely);
                    _ = py.attributeError("Can't set attribute of frozen Atom");
                    return error.PyError;
                }
                if (ptr.*) |old| {
                    try self.validate(atom, old, value);
                    defer old.decref();
                    ptr.* = value.newref();
                    try self.base.notifyUpdate(atom, old, value);
                } else {
                    const old = py.None();
                    defer old.decref();
                    try self.validate(atom, old, value);
                    ptr.* = value.newref();
                    try self.base.notifyCreate(atom, value);
                }
                return; // Ok
            } else {
                // @branchHint(.cold);
                _ = py.attributeError("Member has no unlikelyslot");
                return error.PyError;
            }
        }

        // Default delattr implementation
        pub fn delattr(self: *Self, atom: *AtomBase) !void {
            if (atom.info.is_frozen) {
                // @branchHint(.unlikely);
                _ = py.attributeError("Can't delete attribute of frozen Atom");
                return error.PyError;
            }
            if (atom.slotPtr(self.base.info.index)) |ptr| {
                if (ptr.*) |value| {
                    ptr.* = null;
                    defer value.decref();
                    try self.base.notifyDelete(atom, value);
                }
                // Else nothing to do
            } else {
                // @branchHint(.cold);
                _ = py.attributeError("Member has no slot");
                return error.PyError;
            }
        }

        pub inline fn validate(self: *Self, atom: *AtomBase, oldvalue: *Object, newvalue: *Object) !void {
            if (spec.validate) |validator| {
                return validator(@ptrCast(self), atom, oldvalue, newvalue);
            }
            // else do nothing
        }


//         // Base class provides the slot behavior with no validation
//         pub fn __get__(self: *Self, obj: ?*AtomBase, _: ?*Object) ?*Object {
//             if (obj) |atom| {
//                 // @branchHint(.likely);
//                 if (!atom.typeCheckSelf()) {
//                     // @branchHint(.cold);
//                     return py.typeError("Atom");
//                 }
//                 return @ptrCast(spec.getattr(@ptrCast(self), atom, obj) catch null);
//             } else {
//                 // @branchHint(.cold);
//                 return @ptrCast(self.newref());
//             }
//         }
//
//         pub fn __set__(self: *Self, atom: *AtomBase, value: ?*Object) c_int {
//             if (!atom.typeCheckSelf()) {
//                 // @branchHint(.cold);
//                 _ = py.typeError("Atom");
//                 return -1;
//             }
//             if (value) |v| {
//                 // @branchHint(.likely);
//                 spec.setattr(self, atom, v) catch return -1;
//             } else {
//                 spec.delattr(self, atom) catch return -1;
//             }
//             return 0;
//         }

        const type_slots = [_]py.TypeSlot{
            .{ .slot = py.c.Py_tp_init, .pfunc = @constCast(@ptrCast(&init)) },
            .{ .slot = py.c.Py_tp_descr_get, .pfunc = @constCast(@ptrCast(&__get__)) },
            .{ .slot = py.c.Py_tp_descr_set, .pfunc = @constCast(@ptrCast(&__set__)) },
            .{}, // sentinel
        };
        pub var TypeSpec = py.TypeSpec{
            .name = package_name ++ "." ++ spec.name,
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

}

pub fn deinitModule(mod: *py.Module) void {
    py.clear(&default_name_str);
    MemberBase.deinitType();
    scalars.deinitModule(mod);
}
