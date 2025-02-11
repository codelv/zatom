const py = @import("py.zig");
const std = @import("std");
const Type = py.Type;
const Metaclass = py.Metaclass;
const Object = py.Object;
const Str = py.Str;
const Dict = py.Dict;
const Tuple = py.Tuple;

const atom = @import("atom.zig");
const AtomBase = atom.AtomBase;
const Member = @import("member.zig").Member;

// This is set at startup
var atom_members_str: ?*Str = null;
var slots_str: ?*Str = null;
var weakref_str: ?*Str = null;
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
    pub fn validate_atom_members(self: *Self, members: *Dict) !u16 {
        _ = self;
        if (!members.typeCheckSelf()) {
            _ = py.typeError("atom members must be a dict");
            return error.PyError;
        }
        var pos: isize = 0;
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

    // Create an AtomBase subclass
    pub fn init(self: *Self, args: *Tuple, kwargs: ?*Dict) ?*Object {
        _ = self;

        // name, bases, dct
        const kwlist = [_:null][*c]const u8{
            "name",
            "bases",
            "dct",
            "enable_weakrefs",
        };
        var name: *Str = undefined;
        var bases: *Tuple = undefined;
        var dict: *Dict = undefined;
        var enable_weakrefs: bool = undefined;
        py.parseTupleAndKeywords(args, kwargs, "UOO|p", @ptrCast(&kwlist), .{&name, &bases, &dict, &enable_weakrefs}) catch return null;
        if (!bases.typeCheckExactSelf()) {
            return py.typeError("AtomMeta's 2nd arg must be a tuple");
        }
        if (!dict.typeCheckExactSelf()) {
            return py.typeError("AtomMeta's 3rd arg must be a dict");
        }

        const has_slots = dict.contains(@ptrCast(slots_str.?)) catch return null;
        if (!has_slots) {
            // Add __slots__ if not defined
            var slots =
                if (enable_weakrefs)
                    Tuple.newFromArgs(.{weakref_str.?.newref()}) catch return null
                else
                    Tuple.new(0) catch return null;
            defer slots.decref();
            dict.set(@ptrCast(slots_str.?), @ptrCast(slots)) catch return null;
        }

        // TODO: Get members from bases

        // Gather members from the class
        var members = Dict.new() catch return null;
        defer members.decref();
        var pos: isize = 0;
        var slot_count: usize = 0;
        while (dict.next(&pos)) |entry| {
            if (Member.check(entry.value) and Str.check(entry.key)) {
                const member: *Member = @ptrCast(entry.value);
                // TODO: Clone if a this is a base class member
                member.index = @intCast(pos);
                slot_count += 1;
                members.set(entry.key, entry.value) catch return null;
            }
        }


        {
            const stdout = std.io.getStdOut().writer();
            const s = members.str() catch return null;
            defer s.decref();
            const s2 = bases.str() catch return null;
            defer s2.decref();
            stdout.print("AtomMeta.init members: {s} bases: {s}!\n", .{
                s.asString(), s2.asString()
            }) catch return null;
        }

        // Modify the bases to
        const num_bases = bases.size() catch return null;
        if (num_bases == 0) {
            return py.typeError("AtomMeta must contain AtomBase");
        }

        const base = bases.get(0) catch return null; // Borrowed
        if (!base.is(AtomBase.TypeObject)) {
            return py.typeError("AtomMeta must contain AtomBase");
        }

        // Set to true if bases is redefined and we need to decref it
        var owns_bases: bool = false;
        defer if (owns_bases) bases.decref();

        if (slot_count > 0 and slot_count < atom.atom_types.len) {
            const slot_base = atom.atom_types[slot_count].?;
            if (num_bases == 1) {
                // Add the approprate base
                bases = Tuple.newFromArgs(.{slot_base.newref()}) catch return null;
                owns_bases = true;
            } else {
                bases = Tuple.copy(bases) catch return null;
                owns_bases = true;
                bases.set(0, @ptrCast(slot_base.newref())) catch return null;
            }

        } else {
            return py.typeError("TODO: Dynamic slots");
        }

        // Create a new subclass
        const result = Type.new(@ptrCast(TypeObject), name, bases, dict) catch return null;
        var ok: bool = false;
        defer if (!ok) result.decref();
        const cls: *AtomMeta = @ptrCast(result);
        if (cls.set_atom_members(members, null) < 0) {
            return null;
        }
        ok = true;
        return @ptrCast(cls);
    }

    pub fn get_atom_members(self: *Self) ?*Object {
        if (self.atom_members) |members| {
            // Return a proxy
            const proxy = Dict.newProxy(@ptrCast(members)) catch return null;
            return @ptrCast(proxy);
        }
        return py.systemError("AtomMeta members were not initialized");
    }

    pub fn set_atom_members(self: *Self, members: *Dict, _: ?*anyopaque) c_int {
        const count = self.validate_atom_members(members) catch return -1;
        py.setref(@ptrCast(&self.atom_members), @ptrCast(members.newref()));
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
//         .{
//             .ml_name="get_member",
//             .ml_meth=@constCast(@ptrCast(&get_member)),
//             .ml_flags=py.c.METH_O,
//             .ml_doc="Get the atom member with the given name"
//         },
//         .{
//             .ml_name="members",
//             .ml_meth=@constCast(@ptrCast(&get_atom_members)),
//             .ml_flags=py.c.METH_NOARGS,
//             .ml_doc="Get atom members"
//         },
//         .{
//             .ml_name="__new__",
//             .ml_meth=@constCast(@ptrCast(&new)),
//             .ml_flags=py.c.METH_CLASS | py.c.METH_VARARGS|py.c.METH_KEYWORDS,
//             .ml_doc="Create a new subclass"
//         },
        .{} // sentinel
    };

    var type_slots = [_]py.TypeSlot{
        .{.slot=py.c.Py_tp_init, .pfunc=@constCast(@ptrCast(&init))},
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
        .slots=@constCast(@ptrCast(&type_slots)),
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
    slots_str = try Str.internFromString("__slots__");
    errdefer py.clear(@ptrCast(&slots_str));
    weakref_str = try Str.internFromString("__weakref__");
    errdefer py.clear(@ptrCast(&weakref_str));

    try AtomMeta.initType();
    errdefer AtomMeta.deinitType();
    try mod.addObjectRef("AtomMeta", @ptrCast(AtomMeta.TypeObject.?));
}

pub fn deinitModule(mod: *py.Module) void {
    py.clear(@ptrCast(&atom_members_str));
    py.clear(@ptrCast(&weakref_str));
    py.clear(@ptrCast(&slots_str));
    AtomMeta.deinitType();
    _ = mod; // TODO: Remove dead type
}

