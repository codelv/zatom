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

const package_name = @import("api.zig").package_name;

// Base Member class
pub const Member = extern struct {
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;
    pub const BaseType = Object.BaseType;
    const Self = @This();

    base: BaseType,
    name: ?*Str = null,
    index: u16 = 0,

    // Import the object protocol
    pub usingnamespace py.ObjectProtocol(@This());

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    pub fn new(cls: *Type, args: *Tuple, kwargs: ?*Dict) ?*Member {
        const self: *Member = @ptrCast(cls.genericNew(args, kwargs) catch return null);
        self.name = default_name_str.?.newref();
        return self;
    }

    pub fn get_name(self: *Member) *Str {
        return self.name.?.newref();
    }

    pub fn set_name(self: *Member, value: *Object, _: ?*anyopaque) c_int {
        if (!Str.checkExact(value)) {
            _ = py.typeError("Member name must be a str");
            return -1;
        }
        py.setref(&self.name, value.newref());
        Str.internInPlace(&self.name);
        return 0;
    }

    pub fn get_index(self: *Member) ?*Int {
        return Int.fromNumberUnchecked(self.index);
    }

    pub fn set_index(self: *Member, value: ?*Object, _: ?*anyopaque) c_int {
        if (value) |v| {
            const index = v.castExact(Int) catch {
                _ = py.typeError("Member index must be an int");
                return -1;
            };
            self.index = index.as(u16) catch return 1;
        }
        _ = py.typeError("Member index cannot be deleted");
        return -1;
    }

    pub fn get_slot(self: *Member, atom: *Object) ?*Object {
        _ = self;
        _ = atom;
        return py.typeError("Base member has no slots");
    }

    pub fn set_slot(self: *Member, args: [*]Object, n: isize) c_int {
        _ = self;
        _ = args;
        _ = n;
        return py.typeError("Base member has no slots");
    }

    pub fn clone(self: *Member) ?*Member {
        _ = self;
        return null;
    }

    pub fn dealloc(self: *Self) void {
        self.gcUntrack();
        _ = self.clear();
        self.typeref().impl.tp_free.?(@ptrCast(self));
    }

    pub fn clear(self: *Self) c_int {
        py.clear(@ptrCast(&self.name));
        return 0;
    }

    // Check if object is an atom_meta
    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        return py.visitAll(.{self.name}, visit, arg);
    }

    const getset = [_]py.GetSetDef{
        .{
            .name="name",
            .get=@ptrCast(&get_name),
            .set=@ptrCast(&set_name),
            .doc="Get and set the name to which the member is bound."
        },
        .{
            .name="index",
            .get=@ptrCast(&get_index),
            .set=@ptrCast(&set_index),
            .doc="Get the index to which the member is bound."
        },
        .{} // sentinel
    };

    const methods = [_]py.MethodDef{
        .{
            .ml_name="get_slot",
            .ml_meth=@constCast(@ptrCast(&get_slot)),
            .ml_flags=py.c.METH_O,
            .ml_doc="Get slot value directly"

        },
//         .{
//             .ml_name="clone",
//             .ml_meth=@constCast(@ptrCast(&clone)),
//             .ml_flags=py.c.METH_NOARGS,
//             .ml_doc="Create a copy of the member"
//
//         },
        .{} // sentinel
    };

    const type_slots = [_]py.TypeSlot{
        .{.slot=py.c.Py_tp_new, .pfunc=@constCast(@ptrCast(&new))},
        .{.slot=py.c.Py_tp_dealloc, .pfunc=@constCast(@ptrCast(&dealloc))},
        .{.slot=py.c.Py_tp_traverse, .pfunc=@constCast(@ptrCast(&traverse))},
        .{.slot=py.c.Py_tp_clear, .pfunc=@constCast(@ptrCast(&clear))},
        .{.slot=py.c.Py_tp_methods, .pfunc=@constCast(@ptrCast(&methods))},
        .{} // sentinel
    };
    pub var TypeSpec = py.TypeSpec{
        .name=package_name ++ ".Member",
        .basicsize=@sizeOf(Member),
        .flags=(py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_BASETYPE | py.c.Py_TPFLAGS_HAVE_GC),
        .slots=@constCast(@ptrCast(&type_slots)),
    };

    pub fn initType() !void {
        if (TypeObject != null) return;
        TypeObject = try Type.fromSpec(&TypeSpec);
    }

    pub fn deinitType() void {
        py.clear(@ptrCast(&TypeObject));
    }

};




pub fn initModule(mod: *py.Module) !void {
    default_name_str = try py.Str.internFromString("<undefined>");
    errdefer py.clear(@ptrCast(&default_name_str));
    try Member.initType();
    errdefer Member.deinitType();
    try mod.addObjectRef("Member", @ptrCast(Member.TypeObject.?));
}

pub fn deinitModule(mod: *py.Module) void {
    py.clear(@ptrCast(&default_name_str));
    Member.deinitType();
    _ = mod; // TODO: Remove dead type
}
