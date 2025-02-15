const py = @import("py.zig");
const std = @import("std");
const Str = py.Str;
const Tuple = py.Tuple;
const Dict = py.Dict;
const Object = py.Object;

//
comptime {
    std.debug.assert(isize == py.c.Py_hash_t);
}

pub const ChangeTypes = enum(u8) {
    any,
    create,
    update,
    delete,
    event,
};

pub const ObserverInfo = struct {
    observer: *Object,
    change_types: u8,

    pub fn enabled(self: *ObserverInfo, change_types: u8) bool {
        return self.change_types & change_types != 0;
    }
};

pub const PoolModification = union(enum) {
    add_observer: struct { pool: *ObserverPool, topic: *Str, observer: *Object, change_types: u8 },
    remove_observer: struct { pool: *ObserverPool, topic: *Str, observer: *Object },
    remove_topic: struct { pool: *ObserverPool, topic: *Str },
    clear: *ObserverPool,
    deinit: *ObserverPool,
    release: struct { mgr: *PoolManager, index: u32},
};

pub const PoolGuard = struct {
    const Self = @This();
    pool: *ObserverPool,
    mods: std.ArrayList(PoolModification),

    pub fn init(pool: *ObserverPool, allocator: std.mem.Allocator) !PoolGuard {
        return PoolGuard{
            .pool = pool,
            .mods = std.ArrayList(PoolModification).init(allocator),
        };
    }

    // Has to be a separate function due to the self ptr
    pub fn start(self: *Self) void {
        if (self.pool.guard == null) {
            self.pool.guard = self;
        }
    }

    pub fn finish(self: *Self) !void {
        if (self.pool.guard != self) {
            return;
        }
        self.pool.guard = null; // Clear the guard
        for (self.mods.items) |mod| {
            switch (mod) {
                .add_observer => |data| {
                    defer data.observer.decref();
                    defer data.topic.decref();
                    try data.pool.add_observer(data.topic, data.observer, data.change_types);
                },
                .remove_topic => |data| {
                    defer data.topic.decref();
                    try data.pool.remove_topic(data.topic);
                },
                .remove_observer => |data| {
                    defer data.topic.decref();
                    defer data.observer.decref();
                    try data.pool.remove_observer(data.topic, data.observer);
                },
                .clear => |pool| {
                    try pool.clear();
                },
                .deinit => |pool| {
                    if (pool.guard) |guard| {
                        try guard.mods.append(PoolModification{ .deinit = pool });
                        return;
                    }
                    pool.deinit();
                },
            }
        }
    }

    // Get dynamic size of the guard
    pub fn sizeof(self: *Self) usize {
        var size: usize = @sizeOf(Self);
        size += @sizeOf(PoolModification) * self.mods.capacity;
        return size;
    }

    pub fn deinit(self: *Self) void {
        self.mods.clearAndFree();
    }
};


pub const MemberObservers = struct {
    pub const ObserverMap = std.AutoHashMapUnmanaged(isize, ObserverInfo);
    map: ObserverMap = .{},
    //guard: ?*PoolGuard = null,

    pub fn new(allocator: std.mem.Allocator) py.Error!*MemberObservers {
        const self = try allocator.create(MemberObservers) catch {
            _ = py.memoryError();
            return error.PyError;
        };
        self.* = .{};
        return self;
    }

    pub fn has_observers(self: *const MemberObservers) bool {
        return self.map.count() > 0;
    }

    pub fn has_observer(self: *const MemberObservers, observer: *Object, change_types: u8) py.Error!bool {
        if (self.map.getPtr(try observer.hash())) |info| {
            return info.enabled(change_types);
        }
        return false;
    }

    pub fn add_observer(self: *MemberObservers, allocator: std.mem.Allocator, observer: *Object, change_types: u8) py.Error!void {
        // TODO: guard
        const hash = try observer.hash();
        if (self.map.getPtr(hash)) |item| {
            item.change_types = change_types;
        } else {
            try self.map.put(allocator, hash, ObserverInfo{ .observer = observer.newref(), .change_types = change_types });
        }
    }

    pub fn remove_observer(self: *MemberObservers, observer: *Object) py.Error!void {
        // TODO: guard
        if (self.map.fetchRemove(try observer.hash())) |entry| {
            entry.value.observer.decref();
        }
    }

    pub fn clear(self: *MemberObservers) void {
        var items = self.map.valueIterator();
        // Relase all observer references
        while (items.next()) |item| {
            item.observer.decref();
        }
        self.map.clearRetainingCapacity();
    }

    pub fn deinit(self: *MemberObservers, allocator: std.mem.Allocator) void {
        self.clear();
        self.map.clearAndFree(allocator);
        allocator.destroy(self);
        self.* = undefined;
    }
};

pub const ObserverPool = struct {
    // TODO: Convert to unmanaged...
    // Mapping of observer hash to ObserverInfo
    pub const ObserverMap = std.AutoHashMapUnmanaged(isize, ObserverInfo);

    // Mapping of member index to ObserverMap
    pub const TopicMap = std.AutoHashMapUnmanaged(isize, ObserverMap);

    // Map of member index to observer
    // modifcation of the map invalidates
    map: TopicMap = .{},
    guard: ?*PoolGuard = null,

    pub fn new(allocator: std.mem.Allocator) py.Error!*ObserverPool {
        const pool = allocator.create(ObserverPool) catch {
            _ = py.memoryError();
            return error.PyError;
        };
        pool.* = .{};
        return pool;
    }

    pub fn hasTopic(self: *ObserverPool, topic: *Str) py.Error!bool {
        return self.map.contains(try topic.hash());
    }

    pub fn hasObserver(self: *ObserverPool, topic: *Str, observer: *Object, change_types: u8) py.Error!bool {
        if (self.map.getPtr(try topic.hash())) |observer_map| {
            if (observer_map.getPtr(try observer.hash())) |info| {
                return info.enabled(change_types);
            }
        }
        return false;
    }

    pub fn addObserver(self: *ObserverPool, allocator: std.mem.Allocator, topic: *Str, observer: *Object, change_types: u8) !void {
        if (self.guard) |guard| {
            try guard.mods.append(PoolModification{ .add_observer = .{ .pool = self, .topic = topic.newref(), .observer = observer.newref(), .change_types = change_types } });
            return;
        }

        const topic_hash = try topic.hash();
        if (!self.map.contains(topic_hash)) {
            try self.map.put(allocator, topic_hash, ObserverMap{});
        }
        const observer_map = self.map.getPtr(topic_hash).?;
        const observer_hash = try observer.hash();
        if (observer_map.getPtr(observer_hash)) |item| {
            item.change_types = change_types;
        } else {
            try observer_map.put(allocator, observer_hash, ObserverInfo{ .observer = observer.newref(), .change_types = change_types });
        }
    }

    // Remove an observer from the pool. If the pool is guarded
    // by a modification guard this may require allocation.
    pub fn removeObserver(self: *ObserverPool, allocator: std.mem.Allocator, topic: *Str, observer: *Object) !void {
        if (self.guard) |guard| {
            try guard.mods.append(PoolModification{ .remove_observer = .{ .pool = self, .topic = topic.newref(), .observer = observer.newref() } });
            return;
        }

        const topic_hash = try topic.hash();
        if (self.map.getPtr(topic_hash)) |observer_map| {
            if (observer_map.fetchRemove(try observer.hash())) |entry| {
                entry.value.observer.decref();
            }
            if (observer_map.size == 0) {
                observer_map.deinit(allocator);
                _ = self.map.remove(topic_hash);
            }
        }
    }

    // Remove all observers for a given topic observer from the pool.
    // If the pool is guarded by a modification guard this may require allocation.
    pub fn removeTopic(self: *ObserverPool, allocator: std.mem.Allocator, topic: *Str) !void {
        if (self.guard) |guard| {
            try guard.mods.append(PoolModification{ .remove_topic = .{ .pool = self, .topic = topic.newref() } });
            return;
        }
        if (self.map.fetchRemove(topic)) |entry| {
            var iter = entry.value.keyIterator();
            while (iter.next()) |item| {
                item.observer.decref();
            }
            entry.value.deinit(allocator);
        }
    }

    // Remove all observers from the pool. If the pool is guarded
    // by a modification guard this may require allocation.
    pub fn clear(self: *ObserverPool, allocator: std.mem.Allocator) !void {
        if (self.guard) |guard| {
            try guard.mods.append(PoolModification{ .clear = self });
            return;
        }
        var topics = self.map.valueIterator();
        while (topics.next()) |observer_map| {
            var items = observer_map.valueIterator();
            // Relase all observer references
            while (items.next()) |item| {
                item.observer.decref();
            }
            observer_map.deinit(allocator);
        }
        self.map.clearRetainingCapacity();
    }

    pub fn notify(self: *ObserverPool, allocator: std.mem.Allocator, topic: *Str, args: *Tuple, kwargs: ?*Dict, change_types: u8) !bool {
        var ok: bool = true;
        if (self.map.getPtr(topic)) |observer_map| {
            var guard = PoolGuard.init(self, allocator);
            defer guard.deinit();
            guard.start(self);
            defer guard.finish() catch {
                ok = false;
            };

            var items = observer_map.valueIterator();
            while (items.next()) |item| {
                if (try item.isTrue()) {
                    if (item.enabled(change_types)) {
                        const result = try item.observer.call(args, kwargs);
                        result.decref();
                    }
                } else {
                    try guard.mods.append(PoolModification{ .remove_observer = .{
                        .pool = self,
                        .topic = topic,
                        .observer = item.observer.newref(),
                    }});
                }
            }
        }
        return ok;
    }

    pub fn sizeof(self: *ObserverPool) usize {
        var size: usize = @sizeOf(ObserverInfo);
        if (self.guard) |guard| {
            size += guard.sizeof();
        }
        size += @sizeOf(TopicMap.Entry) * self.map.capacity();
        var topics = self.map.valueIterator();
        while (topics.next()) |observer_map| {
            size += @sizeOf(ObserverMap.Entry) * observer_map.capacity();
        }
        return size;
    }

    pub fn traverse(self: *ObserverPool, func: py.visitproc, arg: ?*anyopaque) c_int {
        var topics = self.map.valueIterator();
        while (topics.next()) |observer_map| {
            var items = observer_map.valueIterator();
            while (items.next()) |item| {
                const r = py.visit(item.observer, func, arg);
                if (r != 0)
                    return r;
            }
        }
        return 0;
    }

    // Clear the pool and free all memory
    // Doing this with an active guard is considered a programming error
    pub fn deinit(self: *ObserverPool, allocator: std.mem.Allocator) void {
        std.debug.assert(self.guard == null);
        self.clear(allocator) catch unreachable; // There is no guard so it cannot fail
        self.map.deinit(allocator);
        allocator.destroy(self);
        self.* = undefined;
    }
};


pub const PoolManager = struct {
    const PoolList = std.ArrayListUnmanaged(?*ObserverPool);
    const FreeList = std.ArrayListUnmanaged(u32);
    pools: PoolList = .{},
    free_slots: FreeList = .{},

    // Create a new pool
    pub fn new(allocator: std.mem.Allocator) py.Error!*PoolManager {
        const self = allocator.create(PoolManager) catch {
            _ = py.memoryError();
            return error.PyError;
        };
        self.* = .{};
        return self;
    }

    // Get the pool at the given index
    // The caller must be sure they own it
    pub inline fn get(self: PoolManager, index: u32) ?*ObserverPool {
        return self.pools.items[index];
    }

    // Get the index of the next available a pool.
    pub fn acquire(self: *PoolManager, allocator: std.mem.Allocator) py.Error!u32 {
        return self.acquireInternal(allocator) catch {
            _ = py.memoryError();
            return error.PyError;
        };
    }

    // Release a pool back
    pub fn release(self: *PoolManager, allocator: std.mem.Allocator, index: u32) py.Error!void {
        return self.releaseInternal(allocator, index) catch {
            _ = py.memoryError();
            return error.PyError;
        };
    }

    inline fn acquireInternal(self: *PoolManager, allocator: std.mem.Allocator) !u32 {
        if (self.free_slots.items.len == 0) {
            if (self.pools.capacity >= std.math.maxInt(u32)) {
                return error.PyError; // Limit reached
            }
            const pool = try ObserverPool.new(allocator);
            errdefer pool.deinit(allocator);
            try self.pools.append(allocator, pool);
            return @intCast(self.pools.items.len - 1);
        }
        return self.free_slots.pop();
    }

    inline fn releaseInternal(self: *PoolManager, allocator: std.mem.Allocator, index: u32) !void {
        if (self.get(index)) |pool| {
            if (pool.guard) |guard| {
                try guard.mods.append(PoolModification{ .release = .{
                    .mgr = self,
                    .index = index
                } });
                return; // Will be release when guard is done
            }
            try pool.clear(allocator);
        }
        try self.free_slots.append(allocator, index);
    }

    pub fn sizeof(self: *PoolManager) usize {
        var size: usize = @sizeOf(PoolManager);
        size += @sizeOf(?*ObserverPool) * self.pools.capacity;
        size += @sizeOf(u32) * self.free_slots.capacity;
        return size;
    }

    // Clear all the pools
    pub fn clear(self: *PoolManager, allocator: std.mem.Allocator) void {
        for (self.pools.items, 0..) |ptr, i| {
            if (ptr) |pool| {
                pool.deinit(allocator);
            }
            self.pools.items[i] = null;
        }
        self.pools.clearRetainingCapacity();
        self.free_slots.clearRetainingCapacity();
    }

    // Let python visit everything in the pool
    pub fn traverse(self: PoolManager, func: py.visitproc, arg: ?*anyopaque) c_int {
        for (self.pools.items) |ptr| {
            if (ptr) |pool| {
                const r = pool.traverse(func, arg);
                if (r != 0)
                    return r;
            }
        }
        return 0;
    }

    pub fn deinit(self: *PoolManager, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.pools.clearAndFree(allocator);
        self.free_slots.clearAndFree(allocator);
        allocator.destroy(self);
        self.* = undefined;
    }
};
