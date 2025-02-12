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

    // Mapping of observer hash to ObserverInfo
    pub const ObserverMap = std.AutoHashMap(isize, ObserverInfo);

    // Mapping of member index to ObserverMap
    pub const TopicMap = std.AutoHashMap(u16, ObserverMap);

    // Map of member index to observer
    // modifcation of the map invalidates
    map: TopicMap,
    guard: ?*PoolGuard = null,

    pub fn init(allocator: std.mem.Allocator) !*ObserverPool {
        const pool = try allocator.create(ObserverPool);
        pool.map = TopicMap.init(allocator);
        return pool;
    }

    pub fn add_observer(self: *ObserverPool, topic: u16, observer: *Object, change_types: u8) !void {
        if (self.guard) |guard| {
            try guard.mods.append(PoolModification{ .add_observer = .{ .pool = self, .topic = topic, .observer = observer.newref(), .change_types = change_types } });
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
    pub fn remove_observer(self: *ObserverPool, topic: u16, observer: *Object) !void {
        if (self.guard) |guard| {
            try guard.mods.append(PoolModification{ .remove_observer = .{ .pool = self, .topic = topic, .observer = observer.newref() } });
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
    pub fn remove_topic(self: *ObserverPool, topic: u16) !void {
        if (self.guard) |guard| {
            try guard.mods.append(PoolModification{ .remove_topic = .{ .pool = self, .topic = topic } });
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
    pub fn clear(self: *ObserverPool) !void {
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
            observer_map.deinit();
        }
        self.map.clearRetainingCapacity();
    }

    pub fn notify(self: *ObserverPool, topic: u16, args: *Tuple, kwargs: ?*Dict, change_types: u8) !bool {
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
                    try guard.mods.add(PoolModification{ .remove_observer = .{
                        .pool = self,
                        .topic = topic,
                        .observer = item.observer.newref(),
                    } });
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
        self.map.deinit();
    }
};
