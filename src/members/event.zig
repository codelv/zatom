const py = @import("../py.zig");
const std = @import("std");
const Object = py.Object;
const Type = py.Type;
const Dict = py.Dict;
const Tuple = py.Tuple;
const Str = py.Str;
const package_name = @import("../api.zig").package_name;
const AtomBase = @import("../atom.zig").AtomBase;
const member = @import("../member.zig");
const MemberBase = member.MemberBase;
const StorageMode = member.StorageMode;
const Member = member.Member;

const InstanceMember = @import("instance.zig").InstanceMember;

var event_str: ?*Str = null;
var type_str: ?*Str = null;
var name_str: ?*Str = null;
var object_str: ?*Str = null;
var value_str: ?*Str = null;

pub const EventBinder = extern struct {
    const Self = @This();
    // Reference to the type. This is set in ready
    pub var TypeObject: ?*py.Type = null;
    base: Object,
    atom: *AtomBase,
    member: *EventMember,

    pub usingnamespace py.ObjectProtocol(Self);

    // Type check the given object. This assumes the module was initialized
    pub fn check(obj: *Object) bool {
        return obj.typeCheck(TypeObject.?);
    }

    pub fn new(cls: *Type, args: *Tuple, _: ?*Dict) ?*Self {
        var _member: *EventMember = undefined;
        var _atom: *AtomBase = undefined;
        args.parseTyped(.{ &_member, &_atom }) catch return null;
        const self: *Self = @ptrCast(cls.genericNew(null, null) catch return null);
        self.member = _member.newref();
        self.atom = _atom.newref();
        return self;
    }

    pub fn call(self: *Self, args: *Tuple, kwargs: ?*Dict) ?*Object {
        if (kwargs != null and kwargs.?.sizeUnchecked() > 0) {
            return py.typeError("An event cannot be triggered with keyword arguments", .{});
        }
        const n = args.size() catch return null;
        if (n > 1) {
            return py.typeError("An event can be triggered with at most 1 argument", .{});
        }
        const value = if (n == 0) py.None() else args.getUnsafe(0).?;
        EventMember.Impl.setattr(@ptrCast(self.member), self.atom, value) catch return null;
        return py.returnNone();
    }

    // --------------------------------------------------------------------------
    // Methods
    // --------------------------------------------------------------------------
    pub fn bind(self: *Self, callback: *Object) ?*Object {
        if (!callback.isCallable()) {
            return py.typeError("Event callback must be callable", .{});
        }
        const topic = self.member.base.name;
        self.atom.addDynamicObserver(topic, callback, 0xff) catch return null;
        return py.returnNone();
    }

    pub fn unbind(self: *Self, callback: *Object) ?*Object {
        const topic = self.member.base.name;
        self.atom.removeDynamicObserver(topic, callback) catch return null;
        return py.returnNone();
    }

    pub fn richcompare(self: *Self, other: *EventBinder, op: c_int) ?*Object {
        if (op == py.c.Py_EQ) {
            if (!other.typeCheckSelf()) {
                return py.returnFalse(); // Not the assumed type
            }
            return py.returnBool(self.member == other.member and self.atom == other.atom);
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
        py.clearAll(.{ &self.atom, &self.member });
        return 0;
    }

    pub fn traverse(self: *Self, visit: py.visitproc, arg: ?*anyopaque) c_int {
        return py.visitAll(.{ self.atom, self.member }, visit, arg);
    }

    const methods = [_]py.MethodDef{
        .{ .ml_name = "bind", .ml_meth = @constCast(@ptrCast(&bind)), .ml_flags = py.c.METH_O, .ml_doc = "Bind a handler to the event. This is equivalent to observing the event." },
        .{ .ml_name = "unbind", .ml_meth = @constCast(@ptrCast(&unbind)), .ml_flags = py.c.METH_O, .ml_doc = "Unbind a handler from the event. This is equivalent to unobserving the event." },
        .{}, // sentinel
    };

    const type_slots = [_]py.TypeSlot{
        .{ .slot = py.c.Py_tp_new, .pfunc = @constCast(@ptrCast(&new)) },
        .{ .slot = py.c.Py_tp_dealloc, .pfunc = @constCast(@ptrCast(&dealloc)) },
        .{ .slot = py.c.Py_tp_traverse, .pfunc = @constCast(@ptrCast(&traverse)) },
        .{ .slot = py.c.Py_tp_clear, .pfunc = @constCast(@ptrCast(&clear)) },
        .{ .slot = py.c.Py_tp_call, .pfunc = @constCast(@ptrCast(&call)) },
        .{ .slot = py.c.Py_tp_richcompare, .pfunc = @constCast(@ptrCast(&richcompare)) },
        .{ .slot = py.c.Py_tp_methods, .pfunc = @constCast(@ptrCast(&methods)) },
        .{}, // sentinel
    };

    pub var TypeSpec = py.TypeSpec{
        .name = package_name ++ ".EventBinder",
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

// The Event member takes no storage
pub const EventMember = Member("Event", struct {
    // Event takes no storage slot
    pub const storage_mode: StorageMode = .none;

    // Event takes a single argument kind which is passed to an Instance member
    // Must initalize the validate_context to an InstanceMember
    pub fn init(self: *MemberBase, args: *Tuple, kwargs: ?*Dict) !void {
        const kwlist = [_:null][*c]const u8{"kind"};
        var kind: ?*Object = null;
        try py.parseTupleAndKeywords(args, kwargs, "|O", @ptrCast(&kwlist), .{&kind});
        if (kind) |v| {
            // Let InstanceMember figure out if kind is valid
            self.validate_context = try InstanceMember.TypeObject.?.callArgs(.{v});
        }
    }

    pub fn getattr(self: *MemberBase, atom: *AtomBase) !*Object {
        return @ptrCast(try EventBinder.TypeObject.?.callArgs(.{ self, atom }));
    }

    pub fn validate(self: *MemberBase, atom: *AtomBase, oldvalue: *Object, value: *Object) py.Error!void {
        if (self.validate_context) |context| {
            std.debug.assert(InstanceMember.check(context));
            const instance: *InstanceMember = @ptrCast(context);
            try instance.validate(atom, oldvalue, value);
        }
    }

    pub fn setattr(self: *MemberBase, atom: *AtomBase, value: *Object) !void {
        if (self.shouldNotify(atom)) {
            try validate(self, atom, py.None(), value);

            var change = try Dict.new();
            defer change.decref();
            try change.set(@ptrCast(type_str.?), @ptrCast(event_str.?));
            try change.set(@ptrCast(object_str.?), @ptrCast(atom));
            try change.set(@ptrCast(name_str.?), @ptrCast(self.name));
            try change.set(@ptrCast(value_str.?), value);
            try self.notifyChange(atom, change, .event);
        }
    }

    pub fn delattr(_: *MemberBase, _: *AtomBase) !void {
        _ = py.typeError("cannot delete the value of an event", .{});
        return error.PyError;
    }
});

pub fn initModule(mod: *py.Module) !void {
    // Strings used to create the event dict
    inline for (.{ "type", "event", "object", "name", "value" }) |str| {
        @field(@This(), str ++ "_str") = try Str.internFromString(str);
        errdefer py.clear(@field(@This(), str ++ "_str"));
    }

    try EventBinder.initType();
    errdefer EventBinder.deinitType();
    try EventMember.initType();
    errdefer EventMember.deinitType();

    try mod.addObjectRef(EventMember.TypeName, @ptrCast(EventMember.TypeObject.?));
}

pub fn deinitModule(mod: *py.Module) void {
    _ = mod;
    EventBinder.deinitType();
    EventMember.deinitType();
    py.clearAll(.{ &event_str, &type_str, &name_str, &object_str, &value_str });
}
