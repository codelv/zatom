
const py = @import("api.zig").py;
const std = @import("std");
const Object = py.Object;
const Type = py.Type;
const Dict = py.Dict;
const Tuple = py.Tuple;
const Int = py.Int;
const Str = py.Str;
const Function = py.Function;
const Method = py.Method;
const package_name = @import("api.zig").package_name;
const Atom = @import("atom.zig").Atom;

var change_types_str: ?*Str = null;
var change_str: ?*Str = null;
var type_str: ?*Str = null;
var create_str: ?*Str = null;
var update_str: ?*Str = null;
var delete_str: ?*Str = null;
var value_str: ?*Str = null;
var oldvalue_str: ?*Str = null;
var object_str: ?*Str = null;

// Use for @observe("foo")
pub const ObserveHandler = extern struct {
    const Self = @This();
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;
    base: Object,
    topics: ?*Tuple,
    func: ?*Function,
    change_types: u8,

    pub usingnamespace py.ObjectProtocol(Self);

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *const Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    pub fn init(self: *Self, args: *Tuple, kwargs: ?*Dict) c_int {
        const n = args.size() catch return -1;
        for (0..n) |i| {
            const name: *Str = @ptrCast(args.getUnsafe(i).?);
            if (!name.typeCheckSelf()) {
                return py.typeErrorObject(-1, "observe attribute name must be a string, got '{s}' instead", .{ name.typeName() });
            }

            const data = name.data();
            if (std.mem.indexOf(u8, data, ".")) |j| {
                if (j <= 1 or j+1 >= data.len or std.mem.count(u8, data, ".") > 1) {
                    return py.typeErrorObject(-1, "cannot observe '{s}', only a single extension with non-empty values is supported", .{ data });
                }
            }
        }
        self.topics = args.newref();

        if (kwargs) |kw| {
            if (kw.get(@ptrCast(change_types_str.?))) |r| {
                if (!Int.check(r)) {
                    return py.typeErrorObject(-1, "change_types must be an int", .{});
                }
                const val = Int.as(@ptrCast(r), u8) catch return -1;
                self.change_types = val;
            } else {
                return py.typeErrorObject(-1, "observe takes one kwarg 'change_types'", .{});
            }
        } else {
            self.change_types = 0xff;
        }

        return 0;
    }

    pub fn call(self: *Self, args: *Tuple, _: ?*Dict) ?*Object {
        const n = args.size() catch return null;
        if (n != 1 or !Function.check(args.getUnsafe(0).?)) {
            return py.typeErrorObject(null, "observe must wrap a function", .{});
        }
        self.func = @ptrCast(args.getUnsafe(0).?.newref());
        return @ptrCast(self.newref());
    }

    // --------------------------------------------------------------------------
    // Type definition
    // --------------------------------------------------------------------------
    pub fn dealloc(self: *Self) void {
        self.gcUntrack();
        _ = self.clear();
        self.typeref().free(@ptrCast(self));
    }

    pub fn clear(self: *Self) c_int {
        py.clearAll(.{ &self.topics, &self.func });
        return 0;
    }

    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        return py.visitAll(.{ self.topics, self.func }, visit, arg);
    }

    const type_slots = [_]py.TypeSlot{
        .{ .slot = py.c.Py_tp_init, .pfunc = @constCast(@ptrCast(&init)) },
        .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
        .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
        .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
        .{ .slot = py.c.Py_tp_call, .pfunc = @constCast(@ptrCast(&call)) },
        .{}, // sentinel
    };

    pub var TypeSpec = py.TypeSpec{
        .name = package_name ++ ".ObserveHandler",
        .basicsize = @sizeOf(Self),
        .flags = (py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_HAVE_GC),
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

// A callable object which just forwards calls a function using the owner
// as self
pub const StaticObserver = extern struct {
    const Self = @This();
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;
    base: Object,
    func: ?*Function,

    pub usingnamespace py.ObjectProtocol(Self);

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *const Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    pub fn create(_func: *Function) !*StaticObserver {
        const self: *Self = @ptrCast(try TypeObject.?.genericNew(null, null));
        self.func = _func.newref();
        return @ptrCast(self);
    }

    pub fn call(self: *Self, args: *Tuple, _: ?*Dict) ?*Object {
        var change: *Dict = undefined;
        args.parseTyped(.{&change}) catch return null;
        const owner = change.getOrError(@ptrCast(object_str.?)) catch return null;
        return self.func.?.callArgsUnchecked(.{owner, change});
    }

    pub fn __bool__(self: *Self) c_int {
        return @intFromBool(self.func != null);
    }

    // --------------------------------------------------------------------------
    // Type definition
    // --------------------------------------------------------------------------
    pub fn dealloc(self: *Self) void {
        self.gcUntrack();
        _ = self.clear();
        self.typeref().free(@ptrCast(self));
    }

    pub fn clear(self: *Self) c_int {
        py.clearAll(.{ &self.func });
        return 0;
    }

    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        return py.visitAll(.{ self.func }, visit, arg);
    }

    const type_slots = [_]py.TypeSlot{
        .{ .slot = py.c.Py_tp_call, .pfunc = @constCast(@ptrCast(&call)) },
        .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
        .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
        .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
        .{ .slot = py.c.Py_nb_bool, .pfunc = @constCast(@ptrCast(&__bool__)) },
        .{}, // sentinel
    };

    pub var TypeSpec = py.TypeSpec{
        .name = package_name ++ ".StaticObserver",
        .basicsize = @sizeOf(Self),
        .flags = (py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_HAVE_GC),
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

// Use for @observe("foo.bar")
pub const ExtendedObserver = extern struct {
    const Self = @This();
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;
    base: Object,
    func: ?*Function,
    meth: ?*Method,
    attr: ?*Str,

    pub usingnamespace py.ObjectProtocol(Self);

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *const Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    pub fn new(cls: *Type, args: *Tuple, _: ?*Dict) ?*Object {
        var _func: *Function = undefined;
        var _attr: *Str = undefined;
        args.parseTyped(.{&_func, &_attr}) catch return null;
        const self: *Self = @ptrCast(cls.genericNew(null, null) catch return null);
        self.func = _func.newref();
        self.attr = _attr.newref();
        return @ptrCast(self);
    }

    pub fn create(_func: *Function, _attr: *Str) !*ExtendedObserver {
        const self: *Self = @ptrCast(try TypeObject.?.genericNew(null, null));
        self.func = _func.newref();
        self.attr = _attr.newref();
        return @ptrCast(self);
    }

    pub fn call(self: *Self, args: *Tuple, _: ?*Dict) ?*Object {
        var change: *Dict = undefined;
        args.parseTyped(.{&change}) catch return null;

        const change_type = change.getOrError(@ptrCast(type_str.?)) catch return null;
        const owner = change.getOrError(@ptrCast(object_str.?)) catch return null;


        var oldowner: *Object = py.None();
        var newowner: *Object = py.None();
//         var oldvalue: *Object = py.returnNone();
//         defer oldvalue.decref();
//         var newvalue: *Object = py.returnNone();
//         defer newvalue.decref();

        if (change_type.is(create_str.?)) {
            newowner = change.getOrError(@ptrCast(value_str.?)) catch return null;
        } else if (change_type.is(update_str.?)) {
            oldowner = change.getOrError(@ptrCast(oldvalue_str.?)) catch return null;
            newowner = change.getOrError(@ptrCast(value_str.?)) catch return null;
        } else if (change_type.is(delete_str.?)) {
            oldowner = change.getOrError(@ptrCast(value_str.?)) catch return null;
//             if (Atom.check(owner)) {
//                 const atom: *Atom = @ptrCast(owner);
//             }
        }




        if (Atom.check(oldowner) and self.meth != null) {
            const atom: *Atom = @ptrCast(oldowner);
            atom.removeDynamicObserver(self.attr.?, @ptrCast(self.meth.?)) catch return null;
        }
        if (Atom.check(newowner)) {
            const atom: *Atom = @ptrCast(newowner);
            py.xsetref(@ptrCast(&self.meth), @ptrCast(Method.new(self.func.?, owner) catch return null));
            atom.addDynamicObserver(self.attr.?, @ptrCast(self.meth.?), 0xff) catch return null;
        } else if (!newowner.isNone()) {
            return py.typeErrorObject(null, "cannot attach observer '{s}' to non-Atom '{s}", .{
                self.attr.?.data(),
                newowner.typeName(),
            });
        }



        return py.returnNone();
    }

    pub fn __bool__(self: *Self) c_int {
        return @intFromBool(self.attr != null and self.func != null);
    }

    // --------------------------------------------------------------------------
    // Type definition
    // --------------------------------------------------------------------------
    pub fn dealloc(self: *Self) void {
        self.gcUntrack();
        _ = self.clear();
        self.typeref().free(@ptrCast(self));
    }

    pub fn clear(self: *Self) c_int {
        py.clearAll(.{ &self.func, &self.meth, &self.attr });
        return 0;
    }

    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        return py.visitAll(.{ self.func, self.meth, self.attr }, visit, arg);
    }

    const type_slots = [_]py.TypeSlot{
        .{ .slot = py.c.Py_tp_new, .pfunc = @constCast(@ptrCast(&new)) },
        .{ .slot = py.c.Py_tp_call, .pfunc = @constCast(@ptrCast(&call)) },
        .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
        .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
        .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
        .{ .slot = py.c.Py_nb_bool, .pfunc = @constCast(@ptrCast(&__bool__)) },
        .{}, // sentinel
    };

    pub var TypeSpec = py.TypeSpec{
        .name = package_name ++ ".ExtendedObserver",
        .basicsize = @sizeOf(Self),
        .flags = (py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_HAVE_GC),
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

const all_types = .{ ObserveHandler, StaticObserver, ExtendedObserver };

const all_strings = .{
    "change_types", "change", "create", "update", "delete", "oldvalue", "value", "object", "type"
};

pub fn initModule(mod: *py.Module) !void {
    inline for (all_strings) |str| {
        @field(@This(), str ++ "_str") = try Str.internFromString(str);
        errdefer py.clear(@field(@This(), str ++ "_str"));
    }

    inline for (all_types) |T| {
        try T.initType();
        errdefer T.deinitType();
    }

    try mod.addObjectRef("observe", @ptrCast(ObserveHandler.TypeObject.?));
    try mod.addObjectRef("ObserveHandler", @ptrCast(ObserveHandler.TypeObject.?));
    try mod.addObjectRef("ExtendedObserver", @ptrCast(ExtendedObserver.TypeObject.?));
    try mod.addObjectRef("StaticObserver", @ptrCast(StaticObserver.TypeObject.?));

}

pub fn deinitModule(_: *py.Module) void {
    inline for (all_types) |T| {
        T.deinitType();
    }
    inline for (all_strings) |str| {
        py.clear(@field(@This(), str ++ "_str"));
    }
}
