const py = @import("api.zig").py;
const std = @import("std");
const Object = py.Object;
const Type = py.Type;
const Dict = py.Dict;
const Tuple = py.Tuple;
const Int = py.Int;
const Method = py.Method;
const Function = py.Function;
const package_name = @import("api.zig").package_name;
const AtomBase = @import("atom.zig").AtomBase;

pub fn MethodWrapper(comptime T: type) type {
    return extern struct {
        const Self = @This();
        // Reference to the type. This is set in ready
        pub var TypeObject: ?*Type = null;
        base: Object,
        ref: *T,
        func: *Function,
        hash: isize,

        pub usingnamespace py.ObjectProtocol(Self);

        // Type check the given object. This assumes the module was initialized
        pub fn check(obj: *const Object) bool {
            return obj.typeCheck(TypeObject.?);
        }

        pub fn new(cls: *Type, args: *Tuple, _: ?*Dict) ?*Self {
            var method: *Method = undefined;
            args.parseTyped(.{&method}) catch return null;
            const self: *Self = @ptrCast(cls.genericNew(null, null) catch return null);
            const owner = method.getSelf() catch return null;
            if (!T.check(owner)) {
                return py.typeErrorObject(null, "MethodWrapper owner is not the correct type", .{});
            }
            return self;
        }

        // Resolve the reference
        // should return a borrowed reference
        pub fn resolve(self: *Self) !*Object {
            switch (T) {
                AtomBase => self.ref.data(),
                Object => @ptrCast(py.c.PyWeakref_GET_OBJECT(self.ref)),
                else => @compileError("MethodWrapper resolve not implemented for " ++ @typeName(T)),
            }
        }

        pub fn call(self: *Self, args: *Tuple, kwargs: ?*Dict) ?*Object {
            if (self.resolve()) |owner| {
                const meth = Method.new(self.func, owner) catch return null;
                defer meth.decref();
                return meth.call(args, kwargs) catch null;
            }
            return py.returnNone();
        }

        // --------------------------------------------------------------------------
        // Methods
        // --------------------------------------------------------------------------
        pub fn __bool__(self: *Self) ?*Object {
            return py.notNull(self.resolve());
        }

        pub fn __hash__(self: *Self) ?*Object {
            return @ptrCast(Int.newUnchecked(self.hash));
        }

        pub fn richcompare(self: *Self, other: *T, op: c_int) ?*Object {
            if (op == py.c.Py_EQ) {
                if (!other.typeCheckSelf()) {
                    return py.returnFalse(); // Not the assumed type
                }
                return py.returnBool(self.ref == other.ref and self.func == other.func);
            }
            return py.returnNotImplemented();
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
            py.clearAll(.{ &self.ref, &self.func });
            return 0;
        }

        pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
            return py.visitAll(.{ self.ref, self.func }, visit, arg);
        }

        const type_slots = [_]py.TypeSlot{
            .{ .slot = py.c.Py_tp_new, .pfunc = @constCast(@ptrCast(&new)) },
            .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
            .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
            .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
            .{ .slot = py.c.Py_tp_call, .pfunc = @constCast(@ptrCast(&call)) },
            .{ .slot = py.c.Py_tp_richcompare, .pfunc = @constCast(@ptrCast(&richcompare)) },
            .{ .slot = py.c.Py_nb_bool, .pfunc = @constCast(@ptrCast(&__bool__)) },
            .{ .slot = py.c.Py_nb_hash, .pfunc = @constCast(@ptrCast(&__hash__)) },
            .{}, // sentinel
        };

        pub var TypeSpec = py.TypeSpec{
            .name = package_name ++ "." ++ @typeName(T) ++ "MethodWrapper",
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
}

const all_types = .{ MethodWrapper(Object), MethodWrapper(AtomBase) };

pub fn initModule(_: *py.Module) !void {
    inline for (all_types) |T| {
        try T.initType();
        errdefer T.deinitType();
    }
}

pub fn deinitModule(_: *py.Module) void {
    inline for (all_types) |T| {
        T.deinitType();
    }
}
