const py = @import("py.zig");
const std = @import("std");
const Type = py.Type;
const Metaclass = py.Metaclass;
const Object = py.Object;
const Str = py.Str;
const Int = py.Int;
const Dict = py.Dict;
const Tuple = py.Tuple;

const atom = @import("atom.zig");
const AtomBase = atom.AtomBase;
const MemberBase = @import("member.zig").MemberBase;
const observer_pool = @import("observer_pool.zig");
const PoolManager = observer_pool.PoolManager;
const ObserverPool = observer_pool.ObserverPool;

// This is set at startup
var atom_members_str: ?*Str = null;
var slots_str: ?*Str = null;
var weakref_str: ?*Str = null;
const package_name = @import("api.zig").package_name;

// A metaclass
pub const AtomMeta = extern struct {
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*Type = null;
    const AtomMembers = std.ArrayListUnmanaged(*MemberBase);
    const Self = @This();

    base: Metaclass,
    atom_members: ?*AtomMembers = null,
    pool_manager: ?*PoolManager = null,
    static_observers: ?*ObserverPool = null,
    slot_count: u16 = 0,

    // Import the object protocol
    pub usingnamespace py.ObjectProtocol(@This());

    pub inline fn check(obj: *Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    // Validate the atom members dict
    pub fn validate_atom_members(self: *Self, members: *Dict) !u16 {
        _ = self;
        if (!members.typeCheckSelf()) {
            _ = py.typeError("atom members must be a dict", .{});
            return error.PyError;
        }
        var pos: isize = 0;
        var count: usize = 0;
        while (members.next(&pos)) |item| {
            if (!Str.check(item.key)) {
                _ = py.typeError("atom members keys must strings", .{});
                return error.PyError;
            }
            if (!MemberBase.check(item.value)) {
                _ = py.typeError("atom members values must Member", .{});
                return error.PyError;
            }
            count += 1;
        }
        if (count > 0xffff) {
            _ = py.typeError("atom member limit reached", .{});
            return error.PyError;
        }
        return @intCast(count);
    }

    // Create an AtomBase subclass
    pub fn new(_: *AtomMeta, args: *Tuple, kwargs: ?*Dict) ?*Object {
        // Any uses of custom tp_new in this function will cause python to error out
        // so temporarily swap it back to the default
        AtomMeta.disableNew();
        defer AtomMeta.enableNew();

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
        py.parseTupleAndKeywords(args, kwargs, "UOO|p", @ptrCast(&kwlist), .{ &name, &bases, &dict, &enable_weakrefs }) catch return null;
        if (!bases.typeCheckExactSelf()) {
            return py.typeError("AtomMeta's 2nd arg must be a tuple", .{});
        }
        if (!dict.typeCheckExactSelf()) {
            return py.typeError("AtomMeta's 3rd arg must be a dict", .{});
        }

        const has_slots = dict.contains(@ptrCast(slots_str.?)) catch return null;
        if (!has_slots) {
            // Add __slots__ if not defined
            var slots =
                if (enable_weakrefs)
                Tuple.packNewrefs(.{weakref_str.?}) catch return null
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
        var last_static_slot: ?usize = null;
        const max_bits: usize = @bitSizeOf(usize);
        var slot_offset: usize = 0;
        while (dict.next(&pos)) |entry| {
            if (MemberBase.check(entry.value) and Str.check(entry.key)) {
                // TODO: Clone if a this is a base class member
                const member: *MemberBase = @ptrCast(entry.value);
                member.name = @ptrCast(entry.key);
                switch (member.info.storage_mode) {
                    .pointer => {
                        member.info.index = @intCast(slot_count);
                        slot_count += 1;
                    },
                    .static => {
                        // Check if there is room in the last spot;
                        const space_remaining = max_bits -| slot_offset;
                        // The reason we add 2 is because we have to reservere 1
                        // extra bit to account for a "null" in order to
                        // preserve the `default` behavior
                        const bitsize = @as(usize, member.info.width) + 2;
                        const can_fit = bitsize < space_remaining;

                        if (last_static_slot == null or !can_fit) {
                            // Start a new static slot
                            member.info.index = @intCast(slot_count);
                            last_static_slot = slot_count;
                            member.info.offset = 0;
                            slot_offset = bitsize; // Reset slot offset
                            slot_count += 1; // This consumes a slot
                        } else {
                            // Reuse the space from the last static slot
                            member.info.index = @intCast(last_static_slot.?);
                            member.info.offset = @intCast(slot_offset);
                            slot_offset += bitsize;
                        }
                    },
                    .none => {}, // No-op
                }
                members.set(entry.key, @ptrCast(member)) catch return null;
            }
        }

        // Modify the bases to
        const num_bases = bases.size() catch return null;
        if (num_bases == 0) {
            _ = py.typeError("AtomMeta must contain AtomBase", .{});
            return null;
        }

        const base = bases.get(0) catch return null; // Borrowed
        if (!base.is(AtomBase.TypeObject)) {
            return py.typeError("AtomMeta must contain AtomBase", .{});
        }

        // Set to true if bases is redefined and we need to decref it
        var owns_bases: bool = false;
        defer if (owns_bases) bases.decref();

        if (slot_count > 1 and slot_count < atom.atom_types.len) {
            const slot_base = atom.atom_types[slot_count].?;
            if (num_bases == 1) {
                // Add the approprate base
                bases = Tuple.packNewrefs(.{slot_base}) catch return null;
                owns_bases = true;
            } else {
                bases = Tuple.copy(bases) catch return null;
                owns_bases = true;
                bases.set(0, @ptrCast(slot_base.newref())) catch return null;
            }
        } else if (slot_count >= atom.atom_types.len) {
            return py.typeError("TODO: Dynamic slots", .{});
        } // else no change needed

        // Create a new subclass
        const cls: *AtomMeta = @ptrCast(Type.new(TypeObject.?, name, bases, dict) catch return null);
        var ok: bool = false;
        defer if (!ok) cls.decref();
        if (cls.set_atom_members(members, null) < 0) {
            return null;
        }
        cls.pool_manager = PoolManager.new(py.allocator) catch return null;
        defer if (!ok) cls.pool_manager.?.deinit(py.allocator);
        ok = true;
        return @ptrCast(cls);
    }

    pub fn get_atom_members(self: *Self) ?*Object {
        if (self.atom_members) |members| {
            // Return a proxy
            // const proxy = Dict.newProxy(@ptrCast(members)) catch return null;
            var dict = Dict.new() catch return null;
            var ok: bool = false;
            defer if (!ok) dict.decref();
            for (members.items) |member| {
                dict.set(@ptrCast(member.name), @ptrCast(member)) catch return null;
            }
            ok = true;
            return @ptrCast(dict);
        }
        return py.systemError("AtomMeta members were not initialized", .{});
    }

    pub fn set_atom_members(self: *Self, members: *Dict, _: ?*anyopaque) c_int {
        const count = self.validate_atom_members(members) catch return -1;
        //py.setref(@ptrCast(&self.atom_members), @ptrCast(members.newref()));
        self.slot_count = count;

        if (self.atom_members) |old| {
            for (old.items) |member| {
                member.decref();
            }
            old.clearRetainingCapacity();
        } else {
            const ptr = py.allocator.create(AtomMembers) catch {
                _ = py.memoryError();
                return -1;
            };
            ptr.* = .{};
            self.atom_members = ptr;
        }
        const members_array = self.atom_members.?;
        var pos: isize = 0;
        while (members.next(&pos)) |entry| {
            // Assign the owner and copy into our array
            const member: *MemberBase = @ptrCast(entry.value);
            py.xsetref(@ptrCast(&member.owner), @ptrCast(self.newref()));
            members_array.append(py.allocator, member.newref()) catch {
                _ = py.memoryError();
                return -1;
            };
        }
        return 0;
    }

    pub fn get_member(self: *Self, name: *Object) ?*Object {
        if (!Str.check(name)) {
            return py.typeError("Invalid arguments: Signature is get_member(name: str)", .{});
        }
        const member_name: *Str = @ptrCast(name);
        if (self.atom_members) |members| {
            for (members.items) |member| {
                // Since names are interned they can be compared with pointers
                if (member.name == member_name) {
                    return @ptrCast(member.newref());
                }
            }
        }
        return py.systemError("Members are not initialized", .{});
    }

    pub fn get_slot_count(self: *Self) ?*Int {
        return Int.new(self.slot_count) catch return null;
    }

    // --------------------------------------------------------------------------
    // Type definition
    // --------------------------------------------------------------------------
    pub fn clear(self: *Self) c_int {
        if (self.pool_manager) |mgr| {
            mgr.deinit(py.allocator);
            self.pool_manager = null;
        }
        // py.clear(&self.atom_members);
        if (self.atom_members) |members| {
            for (members.items) |member| {
                member.decref();
            }
            members.deinit(py.allocator);
            self.atom_members = null;
        }
        return 0;
    }

    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        if (self.pool_manager) |mgr| {
            return mgr.traverse(visit, arg);
        }
        //return py.visit(self.atom_members, visit, arg);
        if (self.atom_members) |members| {
            for (members.items) |member| {
                const r = py.visit(member, visit, arg);
                if (r != 0)
                    return r;
            }

        }
        return 0;
    }

    pub fn dealloc(self: *Self) void {
        self.gcUntrack();
        _ = self.clear();
        self.typeref().free(@ptrCast(self));
    }

    const getset = [_]py.GetSetDef{
        .{ .name = "__atom_members__", .get = @ptrCast(&get_atom_members), .set = @ptrCast(&set_atom_members), .doc = "Get and set the atom members" },
        .{ .name = "__slot_count__", .get = @ptrCast(&get_slot_count), .set = null, .doc = "Get the slot count" },
        .{}, // sentinel
    };

    const methods = [_]py.MethodDef{
        .{ .ml_name = "get_member", .ml_meth = @constCast(@ptrCast(&get_member)), .ml_flags = py.c.METH_O, .ml_doc = "Get the atom member with the given name" },
        .{ .ml_name = "members", .ml_meth = @constCast(@ptrCast(&get_atom_members)), .ml_flags = py.c.METH_NOARGS, .ml_doc = "Get atom members" },
        .{}, // sentinel
    };

    const type_slots = [_]py.TypeSlot{
        .{ .slot = py.c.Py_tp_new, .pfunc = @constCast(@ptrCast(&new)) },
        .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
        .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
        .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
        // .{ .slot = py.c.Py_tp_methods, .pfunc = @constCast(@ptrCast(&methods)) },
        .{ .slot = py.c.Py_tp_getset, .pfunc = @constCast(@ptrCast(&getset)) },
        .{}, // sentinel
    };
    pub var TypeSpec = py.TypeSpec{
        .name = package_name ++ ".AtomMeta",
        .basicsize = @sizeOf(AtomMeta),
        .flags = (py.c.Py_TPFLAGS_DEFAULT | py.c.Py_TPFLAGS_BASETYPE | py.c.Py_TPFLAGS_HAVE_GC),
        .slots = @constCast(@ptrCast(&type_slots)),
    };

    pub fn initType() !void {
        if (TypeObject != null) return;
        TypeObject = try Type.fromSpecWithBases(&TypeSpec, @ptrCast(&py.c.PyType_Type));
    }

    pub fn deinitType() void {
        py.clear(&TypeObject);
    }

    // Python 3.12+ does not allow c-metaclasses with a custom tp_new so it does a check and will fail
    // if it is redefined. The workaround is to temporarily swap tp_new back to the default,
    // create the using PyType_FromMetaclas() then swap it back to the custom new so the custom new is
    // still called. Any uses of Type.new in the metaclass also need to do this to use the "super().__new__"
    pub fn enableNew() void {
        TypeObject.?.impl.tp_new = @ptrCast(&new); // Re-enable custom new
    }

    pub fn disableNew() void {
        TypeObject.?.impl.tp_new = py.c.PyType_Type.tp_new; // Disable custom new
    }
};

pub fn initModule(mod: *py.Module) !void {
    atom_members_str = try py.Str.internFromString("__atom_members__");
    errdefer py.clear(&atom_members_str);
    slots_str = try Str.internFromString("__slots__");
    errdefer py.clear(&slots_str);
    weakref_str = try Str.internFromString("__weakref__");
    errdefer py.clear(&weakref_str);

    try AtomMeta.initType();
    errdefer AtomMeta.deinitType();
    try mod.addObjectRef("AtomMeta", @ptrCast(AtomMeta.TypeObject.?));
}

pub fn deinitModule(mod: *py.Module) void {
    py.clear(&atom_members_str);
    py.clear(&weakref_str);
    py.clear(&slots_str);
    AtomMeta.deinitType();
    _ = mod; // TODO: Remove dead type
}
