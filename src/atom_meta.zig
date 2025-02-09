const py = @import("py.zig");
const Type = py.Type;
const Metaclass = py.Metaclass;
const Object = py.Object;
const Str = py.Str;
const Dict = py.Dict;

const Member = @import("members.zig").Member;

// This is set at startup
var atom_members_str: ?*Str = null;
const package_name = @import("api.zig").package_name;

// A metaclass
pub const AtomMeta = extern struct {
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;
    pub const BaseType = Metaclass.BaseType;
    const Self = @This();

    base: BaseType,
    atom_members: ?*Dict = null,
    slot_count: u16 = 0,

    // Import the object protocol
    pub usingnamespace py.ObjectProtocol(@This());

    pub fn check(obj: *Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    // Validate the atom members dict
    pub fn validate_atom_members(self: *Self, value: *Object) !u16 {
        _ = self;
        if (!Dict.check(value)) {
            _ = py.typeError("atom members must be a dict");
            return error.PyError;
        }
        var pos: isize = 0;
        const members: *Dict = @ptrCast(value);
        while (members.next(&pos)) |item| {
            if (!Str.check(item.key)) {
                _ = py.typeError("atom members keys must strings");
                return error.PyError;
            }
            if (!Member.check(item.value)) {
                _ = py.typeError("atom members values must Member");
                return error.PyError;
            }
        }
        if (pos < 0 or pos > 0xffff) {
            _ = py.typeError("atom member limit reached");
            return error.PyError;
        }
        return @intCast(pos);
    }

    // Initialize a subclass
    pub fn init_subclass(self: *Self) ?*Object {
        if (self.atom_members == null) {
            // Move __atom_members__ from dict to ptr
            if (self.getDictPtr()) |dict| {
                if (dict.get(atom_members_str.?)) |members| {
                    if (self.set_atom_members(members, null) < 0) {
                        return null;
                    }
                    // Remove from internal dict
                    dict.del(atom_members_str.?) catch return null;
                }
            }
        }
        if (self.atom_members == null) {
            return py.systemError("atom members uninitialized");
        }
        return py.returnNone();
    }

    pub fn get_atom_members(self: *Self) ?*Object {
        if (self.atom_members) |members| {
            // Return a proxy
            const proxy = Dict.newProxy(@ptrCast(members)) catch return null;
            return @ptrCast(proxy);
        }
        return py.systemError("AtomMeta members were not initialized");
    }

    pub fn set_atom_members(self: *Self, members: *Object, _: ?*anyopaque) c_int {
        const count = self.validate_atom_members(members) catch return -1;
        self.atom_members = @ptrCast(members.newref());
        self.slot_count = count;
        return 0;
    }

    pub fn get_member(self: *Self, name: *Object) ?*Object {
        if (!Str.check(name)) {
            return py.typeError("name must be a string");
        }
        if (self.atom_members) |members| {
            return members.getItemUnchecked(name);
        }
        return py.systemError("Members are not initialized");
    }

    // --------------------------------------------------------------------------
    // Type definition
    // --------------------------------------------------------------------------
    pub fn dealloc(self: *Self) void {
        self.gcUntrack();
        _ = self.clear();
        self.typeref().impl.tp_free.?(@ptrCast(self));
    }

    pub fn clear(self: *Self) c_int {
        py.clear(@ptrCast(&self.atom_members));
        return 0;
    }

    // Check if object is an atom_meta
    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        return py.visitAll(.{self.atom_members}, visit, arg);
    }

    const getset = [_]py.GetSetDef{
        .{
            .name="__atom_members__",
            .get=@ptrCast(&get_atom_members),
            .set=@ptrCast(&set_atom_members),
            .doc="Get and set the atom members"
        },
        .{} // sentinel
    };

    const methods = [_]py.MethodDef{
        .{
            .ml_name="get_member",
            .ml_meth=@constCast(@ptrCast(&get_member)),
            .ml_flags=py.c.METH_O,
            .ml_doc="Get the atom member with the given name"
        },
        .{
            .ml_name="members",
            .ml_meth=@constCast(@ptrCast(&get_atom_members)),
            .ml_flags=py.c.METH_NOARGS,
            .ml_doc="Get atom members"
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
        .name=package_name ++ ".AtomMeta",
        .basicsize=@sizeOf(AtomMeta),
        .flags=(py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_BASETYPE | py.c.Py_TPFLAGS_HAVE_GC),
        .slots=@constCast(@ptrCast(&slots)),
    };

    pub fn initType() !void {
        if (TypeObject != null) return;
        TypeObject = try Type.fromSpecWithBases(&TypeSpec, @ptrCast(&py.c.PyType_Type));
    }
    pub fn deinitType() void {
        py.clear(@ptrCast(&TypeObject));
    }
};


pub fn initModule(mod: *py.Module) !void {
    atom_members_str = try py.Str.internFromString("__atom_members__");
    errdefer py.clear(@ptrCast(&atom_members_str));
    try AtomMeta.initType();
    errdefer AtomMeta.deinitType();
    try mod.addObjectRef("AtomMeta", @ptrCast(AtomMeta.TypeObject.?));
}

pub fn deinitModule(mod: *py.Module) void {
    py.clear(@ptrCast(&atom_members_str));
    AtomMeta.deinitType();
    _ = mod; // TODO: Remove dead type
}

