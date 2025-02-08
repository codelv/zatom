const py = @import("py.zig");
const Type = py.Type;
const Metaclass = py.Metaclass;
const Object = py.Object;
const Str = py.Str;
const Dict = py.Dict;

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

    // Import the object protocol
    pub usingnamespace py.ObjectProtocol(@This());

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    pub fn get_name(self: *Member) *Str {
        return self.name.?.newref();
    }

    pub fn get_slot(self: *Member, atom: *Object) ?*Object {
        _ = self;
        _ = atom;
        return py.returnNone();
    }

//     pub fn set_name(self: *Member, value: *Object) c_int {
//         if (!Str.check(value)) {
//             return py.typeError("Member name must be a str");
//         }
//         return py.setref(&self.name, value.newref());
//     }

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
            .set=null,
            .doc="Get the name to which the member is bound."
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
        .name=package_name ++ ".Member",
        .basicsize=@sizeOf(Member),
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
