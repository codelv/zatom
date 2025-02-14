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

pub const ObserverInfo = struct {
    observer: *Object,
    change_types: u8,

    pub fn enabled(self: *ObserverInfo, change_types: u8) bool {
        return self.change_types & change_types != 0;
    }
};

pub const PoolModification = union(enum) {
    add_observer: struct { pool: *ObserverPool, topic: u16, observer: *Object, change_types: u8 },
    remove_observer: struct { pool: *ObserverPool, topic: u16, observer: *Object },
    remove_topic: struct { pool: *ObserverPool, topic: u16 },
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
                    try data.pool.add_observer(data.topic, data.observer, data.change_types);
                },
                .remove_topic => |data| {
                    try data.pool.remove_topic(data.topic);
                },
                .remove_observer => |data| {
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

    pub fn deinit(self: *Self) void {
        self.mods.clearAndFree();
    }
};

pub const ObserverPool = struct {
    // TODO: Convert to unmanaged...
    // Mapping of observer hash to ObserverInfo
    pub const ObserverMap = std.AutoHashMap(isize, ObserverInfo);

    // Mapping of member index to ObserverMap
    pub const TopicMap = std.AutoHashMap(u16, ObserverMap);

    // Map of member index to observer
    // modifcation of the map invalidates
    map: TopicMap,
    guard: ?*PoolGuard = null,

    pub fn new(allocator: std.mem.Allocator) !*ObserverPool {
        const pool = try allocator.create(ObserverPool);
        pool.map = TopicMap.init(allocator);
        return pool;
    }

    pub fn add_observer(self: *ObserverPool, topic: u16, observer: *Object, change_types: u8) py.Error!void {
        if (self.guard) |guard| {
            guard.mods.append(PoolModification{ .add_observer = .{ .pool = self, .topic = topic, .observer = observer.newref(), .change_types = change_types } }) catch {
                _ = py.memoryError();
                return error.PyError;
            };
            return;
        }
        const hash = try observer.hash();
        if (!self.map.contains(topic)) {
            try self.map.put(topic, ObserverMap.init(self.map.allocator));
        }
        const observer_map = self.map.getPtr(topic).?;
        if (observer_map.getPtr(hash)) |item| {
            item.change_types = change_types;
        } else {
            try observer_map.put(hash, ObserverInfo{ .observer = observer.newref(), .change_types = change_types });
        }
    }

    // Remove an observer from the pool. If the pool is guarded
    // by a modification guard this may require allocation.
    pub fn remove_observer(self: *ObserverPool, topic: u16, observer: *Object) py.Error!void {
        if (self.guard) |guard| {
            guard.mods.append(PoolModification{ .remove_observer = .{ .pool = self, .topic = topic, .observer = observer.newref() } }) catch {
                _ = py.memoryError();
                return error.PyError;
            };
            return;
        }
        if (self.map.getPtr(topic)) |observer_map| {
            const hash = try observer.hash();
            if (observer_map.fetchRemove(hash)) |entry| {
                entry.value.observer.decref();
            }
            if (observer_map.len == 0) {
                self.map.removeByPtr(observer_map);
                observer_map.deinit();
            }
        }
    }

    // Remove all observers for a given topic observer from the pool.
    // If the pool is guarded by a modification guard this may require allocation.
    pub fn remove_topic(self: *ObserverPool, topic: u16) py.Error!void {
        if (self.guard) |guard| {
            guard.mods.append(PoolModification{ .remove_topic = .{ .pool = self, .topic = topic } }) catch {
                _ = py.memoryError();
                return error.PyError;
            };
            return;
        }
        if (self.map.fetchRemove(topic)) |entry| {
            var iter = entry.value.keyIterator();
            while (iter.next()) |item| {
                item.observer.decref();
            }
            entry.value.deinit();
        }
    }

    // Remove all observers from the pool. If the pool is guarded
    // by a modification guard this may require allocation.
    pub fn clear(self: *ObserverPool) py.Error!void {
        if (self.guard) |guard| {
            guard.mods.append(PoolModification{ .clear = self }) catch {
                _ = py.memoryError();
                return error.PyError;
            };
            return;
        }
        var topics = self.map.valueIterator();
        while (topics.next()) |observer_map| {
            var items = observer_map.valueIterator();
            // Relase all observer references
            while (items.next()) |item| {
                item.observer.decref();
            }
            observer_map.deinit();
        }
        self.map.clearRetainingCapacity();
    }

    pub fn notify(self: *ObserverPool, topic: u16, args: *Tuple, kwargs: ?*Dict, change_types: u8) py.Error!bool {
        var ok: bool = true;
        if (self.map.getPtr(topic)) |observer_map| {
            var guard = PoolGuard.init(self, self.map.allocator);
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
                    guard.mods.add(PoolModification{ .remove_observer = .{
                        .pool = self,
                        .topic = topic,
                        .observer = item.observer.newref(),
                    } }) catch {
                        _ = py.memoryError();
                        return error.PyError;
                    };
                }
            }
        }
        return ok;
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
    pub fn deinit(self: *ObserverPool) void {
        std.debug.assert(self.guard == null);
        self.clear() catch unreachable; // There is no guard so it cannot fail
        const allocator = self.map.allocator;
        self.map.deinit();
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
    pub fn acquire(self: PoolManager, allocator: std.mem.Allocator) py.Error!u32 {
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

    inline fn acquireInternal(self: PoolManager, allocator: std.mem.Allocator) !u32 {
        if (self.free_slots.items.len == 0) {
            if (self.pools.capacity >= std.math.maxInt(u32)) {
                return error.PyError; // Limit reached
            }
            const pool = try ObserverPool.new(allocator);
            errdefer allocator.free(pool);
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
            try pool.clear();
        }
        try self.free_slots.append(allocator, index);
    }

    // Clear all the pools
    pub fn clear(self: *PoolManager, allocator: std.mem.Allocator) void {
        _ = allocator; // Needed if pool gets converted to unmanaged objects to sav
        for (self.pools.items, 0..) |ptr, i| {
            if (ptr) |pool| {
                pool.deinit();
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
