const py = @import("api.zig").py;
const std = @import("std");
const Type = py.Type;
const Metaclass = py.Metaclass;
const Object = py.Object;
const Str = py.Str;
const Int = py.Int;
const Dict = py.Dict;
const List = py.List;
const Tuple = py.Tuple;
const Function = py.Function;

const atom = @import("atom.zig");
const Atom = atom.Atom;
const MemberBase = @import("member.zig").MemberBase;
const observer_pool = @import("observer_pool.zig");
const PoolManager = observer_pool.PoolManager;
const ObserverPool = observer_pool.ObserverPool;
const observation = @import("observation.zig");
const ObserveHandler = observation.ObserveHandler;
const ExtendedObserver = observation.ExtendedObserver;
const StaticObserver = observation.StaticObserver;

// This is set at startup
var atom_members_str: ?*Str = null;
var slots_str: ?*Str = null;
var weakref_str: ?*Str = null;
const package_name = @import("api.zig").package_name;


pub fn computeMemoryLayout(
    member: *MemberBase,
    info: *MetaInfo,
) void {
    const max_bits: usize = @bitSizeOf(usize);
    switch (member.info.storage_mode) {
        .pointer => {
            member.info.index = @intCast(info.slot_count);
            info.slot_count += 1;
        },
        .static => {
            // Check if there is room in the last spot;
            const space_remaining = max_bits -| info.slot_offset;
            // The reason we add 2 is because we have to reservere 1
            // extra bit to account for a "null" in order to
            // preserve the `default` behavior
            const bitsize = @as(usize, member.info.width) + 2;
            const can_fit = bitsize < space_remaining;

            if (!info.has_static_slot or !can_fit) {
                // Start a new static slot
                member.info.index = @intCast(info.slot_count);
                info.last_static_slot = info.slot_count;
                info.has_static_slot = true;
                member.info.offset = 0;
                info.slot_offset = @truncate(bitsize); // Reset slot offset
                info.slot_count += 1; // This consumes a slot
            } else {
                // Reuse the space from the last static slot
                member.info.index = @intCast(info.last_static_slot);
                member.info.offset = @intCast(info.slot_offset);
                info.slot_offset += @truncate(bitsize);
            }
        },
        .none => {}, // No-op
    }

}

pub const MetaInfo = packed struct {
    slot_count: u16 = 0,
    has_static_slot: bool = false,
    last_static_slot: u16 = 0,
    slot_offset: u5 = 0,
    reserved: u26 = 0,
};

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
    info: MetaInfo,

    // Import the object protocol
    pub usingnamespace py.ObjectProtocol(@This());

    pub inline fn check(obj: *const Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    // Create an Atom subclass
    pub fn new(meta: *AtomMeta, args: *Tuple, kwargs: ?*Dict) ?*Object {
        return newOrError(meta, args, kwargs) catch return null;
    }

    pub fn newOrError(_: *AtomMeta, args: *Tuple, kwargs: ?*Dict) !*Object {
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
        var enable_weakrefs: bool = false;
        try py.parseTupleAndKeywords(args, kwargs, "UOO|p", @ptrCast(&kwlist), .{ &name, &bases, &dict, &enable_weakrefs });
        if (!bases.typeCheckExactSelf()) {
            try py.typeError("AtomMeta's 2nd arg must be a tuple", .{});
        }
        if (!dict.typeCheckExactSelf()) {
            try py.typeError("AtomMeta's 3rd arg must be a dict", .{});
        }

        if (dict.get(@ptrCast(slots_str.?)) == null) {
            // Add __slots__ if not defined
            const slots =
                if (enable_weakrefs)
                try Tuple.packNewrefs(.{weakref_str.?})
            else
                try Tuple.new(0);
            defer slots.decref();
            try dict.set(@ptrCast(slots_str.?), @ptrCast(slots));
        }

        // Modify the bases
        const num_bases = try bases.size();
        if (num_bases == 0) {
            try py.typeError("AtomMeta must contain Atom", .{});
        }

        var inherited_members = AtomMembers{};
        defer inherited_members.deinit(py.allocator);
        const observers = try List.new(0);
        defer observers.decref();
        const members = try Dict.new();
        defer members.decref();

        var found_atom: bool = false;
        for (0..num_bases) |i| {
            const base = bases.getUnsafe(i).?;
            const is_atom_subclass = try base.isSubclass(@ptrCast(Atom.TypeObject.?));
            if (is_atom_subclass) {
                found_atom = true;
                const atom_base: *AtomMeta = @ptrCast(base);
                if (atom_base.atom_members) |array| {
                    inherited_members.insertSlice(py.allocator, 0, array.items) catch {
                        try py.memoryError();
                    };
                }

            }
        }
        if (!found_atom) {
            try py.typeError("AtomMeta must contain Atom or a subclass", .{});
        }

        // Gather members from the class
        var info = MetaInfo{};
        {
            var pos: isize = 0;
            while (dict.next(&pos)) |entry| {
                if (!Str.check(entry.key)) {
                    continue;
                }
                const attr: *Str = @ptrCast(entry.key);

                if (MemberBase.check(entry.value)) {
                    const member: *MemberBase = @ptrCast(entry.value);
                    member.setName(attr);
                    computeMemoryLayout(member, &info);
                    try members.set(@ptrCast(attr), @ptrCast(member));


                    const member_default_str = try Str.format("_default_{s}", .{attr.data()});
                    defer member_default_str.decref();
                    if (dict.get(@ptrCast(member_default_str))) |func| {
                        if (Function.check(func)) {
                            member.info.default_mode = .method;
                            py.xsetref(&member.default_context, func.newref());
                        }
                        // TODO: else should this throw an error
                    }

                } else if (ObserveHandler.check(entry.value)) {
                    const observer: *ObserveHandler = @ptrCast(entry.value);
                    if (observer.func) |func| {
                        try observers.append(@ptrCast(observer));
                        // Replace the observe handler with the original function
                        // It's safe to modify the value of dict while iterating
                        try dict.set(@ptrCast(attr), @ptrCast(func));
                    }
                }

                // TODO: Look for un
            }
            // TODO: Unfortunately this adds them to the end
            for (inherited_members.items) |member| {
                if (dict.get(@ptrCast(member.name.?)) != null) {
                    continue; // Member redefined
                }
                const new_member: *MemberBase = @ptrCast(try member.cloneOrError());
                defer new_member.decref();
                computeMemoryLayout(new_member, &info);
                try dict.set(@ptrCast(new_member.name.?), @ptrCast(new_member));
                try members.set(@ptrCast(new_member.name.?), @ptrCast(new_member));
            }
        }

        // Create a new subclass
        const cls: *AtomMeta = blk: {
            // Any uses of custom tp_new in this function will cause python to error out
            // so temporarily swap it back to the default
            AtomMeta.disableNew();
            defer AtomMeta.enableNew();
            break :blk @ptrCast(try Type.new(TypeObject.?, name, bases, dict));
        };
        errdefer cls.decref();
        if (cls.set_atom_members(members, null) < 0) {
            return error.PyError;
        }
        // Modify the basicsize so instances allocate the correct size
        cls.info = info;
        cls.updateTypeSize();
        cls.pool_manager = try PoolManager.new(py.allocator);
        try cls.initStaticObservers(observers, members);

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
        return py.systemErrorObject(null, "AtomMeta members were not initialized", .{});
    }

    pub fn set_atom_members(self: *Self, members: *Dict, _: ?*anyopaque) c_int {
        const member_count = self.validateMembers(members) catch return -1;
        //py.setref(@ptrCast(&self.atom_members), @ptrCast(members.newref()));

        if (self.atom_members) |old| {
            for (old.items) |member| {
                member.decref();
            }
            old.clearRetainingCapacity();
        } else {
            const ptr = py.allocator.create(AtomMembers) catch return py.memoryErrorObject(-1);
            ptr.* = .{};
            self.atom_members = ptr;
        }
        const members_array = self.atom_members.?;
        members_array.ensureTotalCapacity(py.allocator, member_count) catch {
            self.atom_members = null; // Failing to clear here will double decref in clear
            return py.memoryErrorObject(-1);
        };
        var pos: isize = 0;
        while (members.next(&pos)) |entry| {
            // Assign the owner and copy into our array
            const member: *MemberBase = @ptrCast(entry.value);
            member.setOwner(@ptrCast(self));
            members_array.appendAssumeCapacity(member.newref());
        }
        return 0;
    }

    // Return a new reference to the member with the given name
    pub fn get_member(self: *Self, name: *Object) ?*Object {
        if (!Str.check(name)) {
            return py.typeErrorObject(null, "Invalid arguments: Signature is get_member(name: str)", .{});
        }
        if (self.getMember(@ptrCast(name))) |member| {
            return @ptrCast(member.newref());
        }
        return py.returnNone();
    }

    pub fn get_slot_count(self: *Self) ?*Int {
        return Int.new(self.info.slot_count) catch return null;
    }

    pub fn add_member(self: *Self, args: [*]*Object, n: isize) ?*Object {
        if (n != 2 or !Str.check(args[0]) or !MemberBase.check(args[1])) {
            return py.typeErrorObject(null, "Invalid arguments: Signature is add_member(cls: AtomMeta, name: str, member: Member)", .{});
        }
        const name: *Str = @ptrCast(args[0]);
        // TODO: Check if string is interned
        const member: *MemberBase = @ptrCast(args[1]);
        if (member.owner != null) {
            // TODO: Support owned and copy static observers
            return py.typeErrorObject(null, "Cannot add a member owned by other Atom class", .{});
        }
        self.setAttr(name, @ptrCast(member)) catch return null;

        if (self.atom_members) |members| {
            var pos: ?u16 = null;
            for (members.items, 0..) |existing, i| {
                // Since names are interned they can be compared with pointers
                if (existing.name == name) {
                    pos = @intCast(i);
                    if (!existing.hasSameMemoryLayout(member)) {
                        return py.typeErrorObject(null, "Replacing a member with a different layout is yet not supported", .{});
                    }
                    break;
                }
            }
            if (pos) |i| {
                // Discard old
                py.setref(@ptrCast(&members.items[i]), @ptrCast(member.newref()));
            } else {
                members.append(py.allocator, member.newref()) catch {
                    return py.memoryErrorObject(null);
                };
            }
            member.setName(name);
            member.setOwner(@ptrCast(self));
            const old_slot_count = self.info.slot_count;
            computeMemoryLayout(member, &self.info);
            if (self.info.slot_count > old_slot_count) {
                self.updateTypeSize();
            }
        } else {
            return py.typeErrorObject(null, "TODO: Add member to empty atom", .{});
        }
        return py.returnNone();
    }

    // --------------------------------------------------------------------------
    // Internal api
    // --------------------------------------------------------------------------
    pub fn updateTypeSize(self: *Self) void {
        if (self.info.slot_count > 1) {
            const extra_slots = self.info.slot_count - 1;
            self.base.impl.ht_type.tp_basicsize = @intCast(@sizeOf(Atom) + extra_slots * @sizeOf(*Object));
        } else {
            self.base.impl.ht_type.tp_basicsize = @intCast(@sizeOf(Atom));
        }
    }

    pub fn initStaticObservers(self: *Self, observers: *List, members: *Dict) !void {
        var pos: usize = 0;
        while (observers.next(&pos)) |item| {
            std.debug.assert(ObserveHandler.check(item));
            const observer: *ObserveHandler = @ptrCast(item);
            if (observer.topics == null or observer.func == null) continue;
            const func = observer.func.?;
            const static_observer = try StaticObserver.create(func);
            defer static_observer.decref();

            var i: usize = 0;
            while (observer.topics.?.next(&i)) |it| {
                std.debug.assert(Str.check(it));
                const topic: *Str = @ptrCast(it);

                if (try self.staticObserverPool()) |pool| {
                    const data = topic.data();
                    if (std.mem.indexOf(u8, data, ".")) |j| {
                        std.debug.assert(j > 1 and j+1 < data.len);
                        const new_topic = try Str.fromSlice(data[0..j]);
                        defer new_topic.decref();
                        const target = members.get(@ptrCast(new_topic));
                        if (target == null) {
                            return py.attributeError("extended observe target '{s}' is invalid. '{s}' has no member with that name", .{
                                new_topic.data(),
                                self.typeName(),
                            });
                        }

                        // The extended attr to observe
                        const attr = try Str.fromSlice(data[j+1..]);
                        defer attr.decref();

                        // Attempt to validate the attr at runtime
                        switch(try MemberBase.checkTopic(@ptrCast(target.?), attr)) {
                            .no => {
                                return py.attributeError("extended observe target '{s}' is invalid. Attribute '{s}' on member '{s}' of '{s}' is not a valid", .{
                                    data,
                                    attr.data(),
                                    new_topic.data(),
                                    self.typeName()
                                });
                            },
                            else => {}, // Can't tell
                        }

                        const extended_observer = try ExtendedObserver.create(func, attr);
                        defer extended_observer.decref();
                        try pool.addObserver(py.allocator, new_topic, @ptrCast(extended_observer), observer.change_types);
                    } else {
                        if (members.get(@ptrCast(topic)) == null) {
                            return py.attributeError("observe target '{s}' is invalid. '{s}' has no member with that name", .{
                                data,
                                self.typeName(),
                            });
                        }
                        try pool.addObserver(py.allocator, topic, @ptrCast(static_observer), observer.change_types);
                    }
                }
            }

        }
    }

    // Validate the atom members dict and return the number of members
    pub fn validateMembers(self: *Self, members: *Dict) !u16 {
        _ = self;
        if (!members.typeCheckSelf())
            try py.typeError("atom members must be a dict", .{});

        var pos: isize = 0;
        while (members.next(&pos)) |item| {
            if (!Str.check(item.key))
                try py.typeError("atom members keys must strings", .{});
            if (!MemberBase.check(item.value))
                try py.typeError("atom members values must Member", .{});
        }
        if (pos < 0 or pos > std.math.maxInt(u16))
            try py.typeError("atom member limit reached", .{});
        return @intCast(pos);
    }

    // Create a pool if one does not exist
    pub fn staticObserverPool(self: *Self) !?*ObserverPool {
        if (self.static_observers) |pool| {
            return pool;
        }
        if (self.pool_manager) |mgr| {
            const pool_index = try mgr.acquire(py.allocator);
            self.static_observers = mgr.get(pool_index);
            return self.static_observers.?;
        }
        try py.systemError("No pool manager", .{});
        unreachable;
    }

    // Get borrowed reference to the member with the given name
    // Assumes that name is already checked to be a Str and was interned
    pub fn getMember(self: *Self, name: *Str) ?*MemberBase {
        if (self.atom_members) |members| {
            for (members.items) |member| {
                // Since names are interned they can be compared with pointers
                if (member.name == name) {
                    return member;
                }
            }
        }
        return null;
    }

    // --------------------------------------------------------------------------
    // Type definition
    // --------------------------------------------------------------------------
    pub fn clear(self: *Self) c_int {
        // The pool owns the static_observers so we don't need to release it
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
        if (self.atom_members) |members| {
            for (members.items) |member| {
                const r = py.visit(member, visit, arg);
                if (r != 0)
                    return r;
            }
        }
        if (self.pool_manager) |mgr| {
            const r = mgr.traverse(visit, arg);
            if (r != 0)
                return r;
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
        .{ .ml_name = "add_member", .ml_meth = @constCast(@ptrCast(&add_member)), .ml_flags = py.c.METH_FASTCALL, .ml_doc = "Add an atom member" },
        .{}, // sentinel
    };

    const type_slots = [_]py.TypeSlot{
        .{ .slot = py.c.Py_tp_new, .pfunc = @constCast(@ptrCast(&new)) },
        .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
        .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
        .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
        .{ .slot = py.c.Py_tp_methods, .pfunc = @constCast(@ptrCast(&methods)) },
        //.{ .slot = py.c.Py_tp_members, .pfunc = @constCast(@ptrCast(&tp_members)) },
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
