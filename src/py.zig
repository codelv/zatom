pub const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", "1");
    @cInclude("Python.h");
});
const std = @import("std");

pub const None = c.Py_None;
pub const True = c.Py_True;
pub const False = c.Py_False;

const VER_312 = 0x030C0000;
const VER_313 = 0x030D0000;

pub const VersionOp = enum {gt, gte, lt, lte, eq, ne};

// Return true if the compile version is over the given value
pub fn versionCheck(
    comptime op: VersionOp,
    comptime version: c_int
) bool {
    const py_ver = c.PY_VERSION_HEX;
    return switch (op) {
        .gt => py_ver > version,
        .gte => py_ver >= version,
        .lt => py_ver < version,
        .lte => py_ver <= version,
        .eq => py_ver == version,
        .ne => py_ver != version,
    };
}

pub fn initialize() !void {
    c.Py_Initialize();
}

pub fn finalize() !void {
    c.Py_Finalize();
}

// Test whether the error indicator is set. If set, return the exception type (the first
// argument to the last call to one of the PyErr_Set* functions or to PyErr_Restore()).
// If not set, return NULL. You do not own a reference to the return value, so you do not
// need to Py_DECREF() it.
// The caller must hold the GIL.
pub fn errorOcurred() ?*Object {
    return c.PyErr_Ocurred();
}

// Clear the error indicator. If the error indicator is not set, there is no effect.
pub fn errorClear() void {
    return c.PyErr_Clear();
}

// Print a standard traceback to sys.stderr and clear the error indicator.
// Unless the error is a SystemExit, in that case no traceback is printed and the
// Python process will exit with the error code specified by the SystemExit instance.
// Call this function only when the error indicator is set.
// Otherwise it will cause a fatal error!
pub fn errorPrint() void {
    if (errorOcurred()) {
        errorPrintUnchecked();
    }
}

// Same as errorPrint but does not check if an error ocurred
pub fn errorPrintUnchecked() void {
    c.PyErr_Print();
}

pub fn errorString(msg: [:0]const u8) void {
    c.PyErr_SetString(@ptrCast(msg));
}

pub fn errorFormat(exc: *Object, msg: [:0]const u8, args: anytype) ?*Object {
    return @call(.auto, c.PyErr_Format, .{@as([*c]c.PyObject, @ptrCast(exc)), msg.ptr}++args);
}

// Helper that is the equivalent to `TypeError(msg)`
pub fn typeError(msg: [:0]const u8) ?*Object {
    c.PyErr_SetString(c.PyExc_TypeError, @ptrCast(msg));
    return null;
}

// Helper that is the equivalent to `SystemError(msg)`
pub fn systemError(msg: [:0]const u8) ?*Object {
    c.PyErr_SetString(c.PyExc_SystemError, @ptrCast(msg));
    return null;
}

// Helper that is the equivalent to `ValueError(msg)`
pub fn valueError(msg: [:0]const u8) ?*Object {
    c.PyErr_SetString(c.PyExc_ValueError, @ptrCast(msg));
    return null;
}

// Clear a reference
pub fn clear(obj: *?*Object) void {
    xsetref(obj, null);
}

// Replaces the macro Py_RETURN_NONE
pub fn returnNone() *Object {
    if (comptime versionCheck(.gte, VER_312)) {
        return @ptrCast(&c._Py_NoneStruct);
    }
    return @ptrCast(c.Py_NewRef(&c._Py_NoneStruct));
}

// Replaces the macro Py_RETURN_TRUE
pub fn returnTrue() *Object {
    if (comptime versionCheck(.gte, VER_312)) {
        return @ptrCast(&c._Py_TrueStruct);
    }
    return @ptrCast(c.Py_NewRef(&c._Py_TrueStruct));
}

// Replaces the macro Py_RETURN_FALSE
pub fn returnFalse() *Object {
    if (comptime versionCheck(.gte, VER_312)) {
        return &c._Py_FalseStruct;
    }
    return @ptrCast(c.Py_NewRef(&c._Py_FalseStruct));
}

// Re-export the visitproc
pub const visitproc = c.visitproc;

// Invoke the visitor func if the object is not null orelse return 0;
pub fn visit(obj: ?*Object, func: visitproc, arg: ?*anyopaque) c_int {
    return if (obj) |p| func.?(@ptrCast(p), arg) else 0;
}

// Invoke the visitor func on all non-null objects and return the first nonzero result if any.
pub fn visitAll(objects: anytype, func: visitproc, arg: ?*anyopaque) c_int {
    inline for(objects) |obj| {
        if (obj) |p| {
            const r = func.?(@ptrCast(p), arg);
            if (r != 0) return r;
        }
    }
    return 0;
}

// Safely release a strong reference to object dst and setting dst to src.
pub fn setref(dst: **Object, src: *Object) void {
    const tmp = dst.*;
    defer tmp.decref();
    dst.* = src;
}

pub fn xsetref(dst: *?*Object, src: ?*Object) void {
    const tmp = dst.*;
    defer if (tmp) |o| o.decref();
    dst.* = src;
}

// Object Protocol
pub fn ObjectProtocol(comptime T: type) type {
    return struct {
        pub fn incref(self: *T) void {
            c.Py_IncRef(@ptrCast(self));
        }

        pub fn decref(self: *T) void {
            c.Py_DecRef(@ptrCast(self));
        }

        // Create a new strong reference to an object: call Py_INCREF()
        // on o and return the object o.
        pub fn newref(self: *T) *T {
            return @ptrCast(c.Py_NewRef(@ptrCast(self)));
        }

        // Returns a new reference to the type
        pub fn typenewref(self: *T) [*c]Type {
            return @ptrCast(c.PyObject_Type(@ptrCast(self)));
        }

        // Returns a borrwed reference to the type
        pub fn typeref(self: *T) *Type {
            return @ptrCast(c.Py_TYPE(@ptrCast(self)));
        }

        pub fn hasAttr(self: *T, attr: *Object) bool {
            return c.PyObject_HasAttr(@ptrCast(self), @ptrCast(attr)) == 0;
        }

        pub fn hasAttrString(self: *Object, attr: [:0]const u8) bool {
            return c.PyObject_HasAttr(@ptrCast(self), @ptrCast(attr)) == 0;
        }

        pub fn hasAttrWithError(self: *Object, attr: *Object) !bool {
            const r = c.PyObject_HasAttrWithError(@ptrCast(self), @ptrCast(attr));
            if ( r < 0 ) return error.PyError;
            return r == 1;
        }

        pub fn hasAttrStringWithError(self: *Object, attr: [:0]const u8) !bool {
            const r = c.PyObject_HasAttrWithError( @ptrCast(self), @ptrCast(attr) );
            if ( r < 0 ) return error.PyError;
            return r == 1;
        }

        pub fn getAttr(self: *T, attr: *Object) !*Object {
            const r = c.PyObject_GetAttr( @ptrCast(self), @ptrCast(attr) );
            if (r == 0 ) return error.PyError;
            return r;
        }

        pub fn getAttrString(self: *T, attr: [:0]const u8) !*Object {
            const r = c.PyObject_GetAttrString( @ptrCast(self), @ptrCast(attr) );
            if (r == 0 ) return error.PyError;
            return r;
        }

        pub fn getAttrOptional(self: *T, attr: *Object) !?*Object {
            var result: ?*Object = undefined;
            const r = c.PyObject_GetOptionalAttr( @ptrCast(self), @ptrCast(attr), @ptrCast(&result) );
            if (r == -1 ) return error.PyError;
            return result;
        }

        // Return the length of object o. If the object o provides either the sequence and mapping
        // protocols, the sequence length is returned. On error, -1 is returned. This is the equivalent
        // to the Python expression len(o).
        pub fn length(self: *T) !usize {
            const s = c.PyObject_Length(@ptrCast(self));
            if (s < 0) {
                return error.PyError;
            }
            return @intCast(s);
        }

        // Same as length but no error checking
        pub fn size(self: *T) isize {
            return c.PyObject_Size(@ptrCast(self));
        }

        // Return element of o corresponding to the object key or NULL on failure.
        // This is the equivalent of the Python expression o[key].
        // Returns a New reference.
        pub fn getItem(self: *T, key: *Object) !*Object {
            if (self.getItemUnchecked(key)) |item| {
                return @ptrCast(item);
            }
            return error.PyError;
        }

        // Calls PyObject_GetItem(self, key). Same as getItem with no error checking.
        // Returns a New reference.
        pub fn getItemUnchecked(self: *T, key: *Object) ?*Object {
            return @ptrCast( c.PyObject_GetItem( @ptrCast(self), @ptrCast(key) ) );
        }

        // Map the object key to the value v.
        // This is the equivalent of the Python statement o[key] = v.
        // This function does not steal a reference to v.
        pub fn setItem(self: *T, key: *Object, value: *Object) !void {
            if (self.setItemUnchecked(key, value) < 0) {
                return error.PyError;
            }
        }

        // Same as setItem without error checking
        pub fn setItemUnchecked(self: *T, key: *Object, value: *Object) c_int {
            return c.PyObject_SetItem( @ptrCast(self), @ptrCast(key), @ptrCast(value) );
        }

        // Remove the mapping for the object key from the object o.
        // This is equivalent to the Python statement del o[key].
        pub fn delItem(self: *T, key: *Object) !void {
            if (self.delItemUnchecked(key) < 0) {
                return error.PyError;
            }
        }

        // Same as delItem without error checking
        pub fn delItemUnchecked(self: *T, key: *Object) c_int {
            return c.PyObject_DelItem( @ptrCast(self), @ptrCast(key) );
        }

        // This is equivalent to the Python expression iter(o).
        // It returns a new iterator for the object argument, or the object itself if the object is
        // already an iterator.  Raises TypeError and returns NULL if the object cannot be iterated.
        pub fn iter(self: *T) !*Object {
            if (c.PyObject_GetIter(@ptrCast(self))) |r| {
                return @ptrCast(r);
            }
            return error.PyError;
        }

        // Compute a string representation of object o. Null and type check the result is a Str.
        pub fn str(self: *T) !*Str {
            if (self.strUnchecked()) |s| {
                if (Str.check(s)) {
                    return @ptrCast(s);
                }
                // Set an error message
                _ = typeError("str did not return a str");
            }
            return error.PyError;
        }

        // Calls PyObject_Str(self). Compute a string representation of object o.
        // Returns the string representation on success, NULL on failure.
        pub fn strUnchecked(self: *T) ?*Object {
            return @ptrCast(c.PyObject_Str(@ptrCast(self)));
        }

        // Compute a bytes representation of object o. NULL is returned on failure and a bytes object on
        // success. This is equivalent to the Python expression bytes(o), when o is not an integer.
        // Unlike bytes(o), a TypeError is raised when o is an integer instead of a zero-initialized bytes object.
        pub fn bytes(self: *T) ?*Object {
            return @ptrCast(c.PyObject_Bytes(@ptrCast(self)));
        }

        pub fn repr(self: *T) ?*Object {
            return @ptrCast(c.PyObject_Repr(@ptrCast(self)));
        }

        // Return non-zero if the object o is of type type or a subtype of type,
        // and 0 otherwise. Both parameters must be non-NULL.
        pub fn typeCheck(self: *T, tp: *Type) bool {
            return c.PyObject_TypeCheck(@ptrCast(self), @ptrCast(tp)) != 0;
        }

        // Return 1 if the class derived is identical to or derived from the class cls,
        // otherwise return 0. In case of an error, return -1.
        // If cls is a tuple, the check will be done against every entry in cls.
        // The result will be 1 when at least one of the checks returns 1, otherwise it will be 0.
        pub fn isSubclass(self: *T, cls: *Object) !bool {
            const r = self.isSubclassUnchecked(cls);
            if (r < 0) return error.PyError;
            return r != 0;
        }

        // Same as isSubclass but does not check for errors
        pub fn isSubclassUnchecked(self: *T, cls: *Object) c_int {
            return c.PyObject_IsSubclass(@ptrCast(self), @ptrCast(cls));
        }

        // Return 1 if inst is an instance of the class cls or a subclass of cls,
        // or 0 if not. On error, returns -1 and sets an exception.
        // If cls is a tuple, the check will be done against every entry in cls.
        // The result will be 1 when at least one of the checks returns 1, otherwise it
        // will be 0.
        pub fn isInstance(self: *T, cls: *Object) !bool {
            const r = self.isInstanceUnchecked(cls);
            if (r < 0) return error.PyError;
            return r != 0;
        }

        // Calls PyObject_IsInstance(self, cls). Same as isInstance but without error checking
        pub fn isInstanceUnchecked(self: *T, cls: *Object) c_int {
            return c.PyObject_IsInstance(@ptrCast(self), @ptrCast(cls));
        }

        // Returns 1 if the object o is considered to be true, and 0 otherwise.
        // This is equivalent to the Python expression `not not o`. On failure, return -1.
        pub fn isTrue(self: *T) !bool {
            const r = self.isTrueUnchecked();
            if (r < 0) return error.PyError;
            return r != 0;
        }

        // Calls PyObject_IsTrue on self. Same as isTrue but without error checking
        pub fn isTrueUnchecked(self: *T) c_int {
            return c.PyObject_IsTrue(@ptrCast(self));
        }

        // Returns 1 if the object o is considered to be true, and 0 otherwise.
        // This is equivalent to the Python expression not not o. On failure, return -1.
        pub fn isNot(self: *T) !bool {
            const r = self.isNotUnchecked();
            if (r < 0) return error.PyError;
            return r != 0;
        }

        // Calls PyObject_Not on self. Same as isNot but without error checking
        pub fn isNotUnchecked(self: *T) c_int {
            return c.PyObject_Not(@ptrCast(self));
        }

        pub fn gcUntrack(self: *T) void {
            c.PyObject_GC_UnTrack(@ptrCast(self));
        }

        // Return a pointer to __dict__ of the object obj. If there is no __dict__,
        // return NULL without setting an exception.
        pub fn getDictPtr(self: *T) ?**Dict {
            return @ptrCast(c._PyObject_GetDictPtr( @ptrCast(self) ) );
        }
    };
}


pub const TypeSlot = c.PyType_Slot;
pub const TypeSpec = c.PyType_Spec;

pub const Object = extern struct {
    pub const BaseType = c.PyObject;

    // The underlying python structure
    impl: BaseType,

    // Import the object protocol
    pub usingnamespace ObjectProtocol(@This());
};



pub const Type = extern struct {
    pub const BaseType = c.PyTypeObject;

    // The underlying python structure
    impl: BaseType,

    // Import the object protocol
    pub usingnamespace ObjectProtocol(@This());

    // Generic handler for the tp_new slot of a type object.
    // Create a new instance using the type’s tp_alloc slot.
    // Returns a new reference
    pub fn genericNew(self: *Type, args: ?*Tuple, kwargs: ?*Dict) !*Object {
        if (self.genericNewUnchecked(args, kwargs)) |obj| {
            return obj;
        }
        return error.PyError;
    }

    // Calls PyType_GenericNew(self, args, kwargs). without error checking
    pub fn genericNewUnchecked(self: *Type, args: ?*Tuple, kwargs: ?*Dict) ?*Object {
        return c.PyType_GenericNew(@ptrCast(self), @ptrCast(args), @ptrCast(kwargs));
    }

    // Return true if the object o is a type object, including instances of types derived
    // from the standard type object. Return 0 in all other cases. This function always succeeds.
    pub fn check(obj: *Object) bool {
        return c.PyType_Check(@ptrCast(obj)) != 0;
    }

    // Return non-zero if the object o is a type object, but not a subtype of the standard type object.
    // Return 0 in all other cases. This function always succeeds.
    pub fn checkExact(obj: *Object) bool {
        return c.PyType_CheckExact(@ptrCast(obj)) != 0;
    }

    // New reference
    pub fn fromSpecWithBases(spec: *TypeSpec, base: *Object) !*Type {
        if (c.PyType_FromSpecWithBases(@ptrCast(spec), @ptrCast(base))) |o| {
            return @ptrCast(o);
        }
        return error.PyError;
    }

    // New reference
    pub fn fromSpec(spec: *TypeSpec) !*Type {
        if (c.PyType_FromSpec(@ptrCast(spec))) |o| {
            return @ptrCast(o);
        }
        return error.PyError;
    }

};


pub const Metaclass = extern struct {
    pub const BaseType = c.PyHeapTypeObject;
    impl: BaseType,
    // Import the object protocol
    pub usingnamespace ObjectProtocol(@This());
};


pub const Bool = extern struct {
    pub const BaseType = c.PyLongObject;

    // The underlying python structure
    impl: BaseType,

    // Import the object protocol
    pub usingnamespace ObjectProtocol(@This());

    pub fn check(obj: *Object) bool {
        return c.PyBool_Check(@ptrCast(obj)) != 0;
    }

    pub fn fromLong(value: c_long) ?*Bool {
        return @ptrCast(c.PyBool_FromLong(value));
    }

};


pub const Int = extern struct {
    pub const BaseType = c.PyLongObject;

    // The underlying python structure
    impl: BaseType,

    // Import the object protocol
    pub usingnamespace ObjectProtocol(@This());

    pub fn fromInt(value: c_long) ?*Int {
        return @ptrCast(c.PyLong_FromLong(value));
    }
    pub const fromLong = fromInt;

};


pub const Float = extern struct {
    pub const BaseType = c.PyFloatObject;

    // The underlying python structure
    impl: BaseType,

    // Import the object protocol
    pub usingnamespace ObjectProtocol(@This());

};


// TODO: Fix zig bug preventing this from importing...
const PyASCIIObject = extern struct {
    ob_base: c.PyObject = .{},
    length: c.Py_ssize_t = 0,
    hash: c.Py_hash_t = 0,
    state: u32 = 0, // TODO: Fix zig bug
};

const PyCompactUnicodeObject = extern struct {
    _base: PyASCIIObject = .{},
    utf8_length: c.Py_ssize_t = 0,
};

const PyUnicodeObject = extern struct {
    _base: PyCompactUnicodeObject,
    data: ?*anyopaque,
};


pub const Str = extern struct {
    pub const BaseType = PyUnicodeObject;

    // The underlying python structure
    impl: BaseType,

    // Import the object protocol
    pub usingnamespace ObjectProtocol(@This());


    // Return true if the object obj is a Unicode object or an instance of a Unicode subtype.
    // This function always succeeds.
    pub fn check(obj: *Object) bool {
        return c.PyUnicode_Check(@as([*c]c.PyObject, @ptrCast(obj))) != 0;
    }

    // Return true if the object obj is a Unicode object, but not an instance of a subtype.
    // This function always succeeds.
    pub fn checkExact(obj: *Object) bool {
        return c.PyUnicode_CheckExact(@ptrCast(obj)) != 0;
    }

    // Return the length of the Unicode string, in code points. unicode has to be a
    // Unicode object in the “canonical” representation (not checked).
    pub fn length(self: *Str) isize {
        return c.PyUnicode_GET_LENGTH(@ptrCast(self));
    }

    // Return 1 if the string is a valid identifier according to the language definition, section
    // Identifiers and keywords. Return 0 otherwise.
    pub fn isIdentifier(self: *Str) bool {
        return c.PyUnicode_IsIdentifier(@ptrCast(self)) == 1;
    }

    // Create a Unicode object from the char buffer str. The bytes will be interpreted as
    // being UTF-8 encoded. The buffer is copied into the new object.
    // The return value might be a shared object, i.e. modification of the
    // data is not allowed.
    pub fn fromSlice(str: []const u8) !*Str {
        if (c.PyUnicode_FromStringAndSize(str.ptr, str.len)) |o| {
            return @ptrCast(o);
        }
        return error.PyError;
    }

    pub fn fromString(str: [*c]const u8) !*Str {
        if (c.PyUnicode_FromString(str)) |o| {
            return @ptrCast(o);
        }
        return error.PyError;
    }

    // A combination of PyUnicode_FromString() and PyUnicode_InternInPlace(),
    // meant for statically allocated strings.
    // Return a new (“owned”) reference to either a new Unicode string object
    // that has been interned, or an earlier interned string object with
    // the same value.
    pub fn internFromString(str: [:0]const u8) !*Str {
        if (c.PyUnicode_InternFromString(str)) |o| {
            return @ptrCast(o);
        }
        return error.PyError;
    }

};

pub const Tuple = extern struct {
    pub const BaseType = c.PyTupleObject;

    // The underlying python structure
    impl: BaseType,

    // Import the object protocol
    pub usingnamespace ObjectProtocol(@This());

    pub fn parse(self: *Tuple, format: [:0]const u8, args: anytype) !void {
        const r = @call(.auto, c.PyArg_ParseTuple, .{
            @as([*c]c.PyObject, @ptrCast(self)),
            format
        } ++ args);
        if (r == 0) return error.PyError;
    }


};

pub const List = extern struct {
    pub const BaseType = c.PyListObject;

    // The underlying python structure
    impl: BaseType,

    // Import the object protocol
    pub usingnamespace ObjectProtocol(@This());

};

pub const Dict = extern struct {
    pub const BaseType = c.PyDictObject;
    // Iteration item
    pub const Item = struct{key: *Object, value: *Object};

    // The underlying python structure
    impl: BaseType,

    // Import the object protocol
    pub usingnamespace ObjectProtocol(@This());

    // Return true if p is a dict object or an instance of a subtype of the dict type. This function always succeeds.
    pub fn check(obj: *Object) bool {
        return c.PyDict_Check(@ptrCast(obj)) != 0;
    }

    // Return true if p is a dict object, but not an instance of a subtype of the dict type. This function always succeeds.
    pub fn checkExact(obj: *Object) bool {
        return c.PyDict_Check(@ptrCast(obj)) != 0;
    }

    // Return a new empty dictionary, or NULL on failure.
    // Returns a new reference
    pub fn new() !*Dict {
        if (c.PyDict_New()) |r| {
            return @ptrCast(r);
        }
        return error.PyError;
    }

    // Return a new dictionary that contains the same key-value pairs as p.
    // Returns a new reference
    pub fn copy(other: *Object) !*Dict {
        if (c.PyDict_Copy(@ptrCast(other))) |r| {
            return @ptrCast(r);
        }
        return error.PyError;
    }

    // Return a types.MappingProxyType object for a mapping which enforces read-only behavior.
    // This is normally used to create a view to prevent modification of the dictionary for non-dynamic
    // class types. Returns a new reference
    pub fn newProxy(mapping: *Object) !*Dict {
        if (c.PyDictProxy_New(@ptrCast(mapping))) |r| {
            return @ptrCast(r);
        }
        return error.PyError;
    }

    // Return a borrowed reference to the object from dictionary p which has a key key.
    // Return NULL if the key key is missing without setting an exception.
    pub fn get(self: *Dict, key: *Object) ?*Object {
        return @ptrCast(c.PyDict_GetItem(@ptrCast(self), @ptrCast(key)));
    }

    pub fn getString(self: *Dict, key: [:0]const u8) ?*Object {
        return @ptrCast(c.PyDict_GetItemString(@ptrCast(self), @ptrCast(key)));
    }

    // Remove the entry in dictionary p with key key. key must be hashable; if it isn’t,
    // TypeError is raised. If key is not in the dictionary, KeyError is raised.
    // Return 0 on success or -1 on failure.
    pub fn del(self: *Dict, key: *Object) !void {
        if (c.PyDict_DelItem(@ptrCast(self), @ptrCast(key))) {
            return error.PyError;
        }
    }

    pub fn delString(self: *Dict, key: [:0]const u8) !void {
        if (c.PyDict_DelItemString(@ptrCast(self), @ptrCast(key)) < 0) {
            return error.PyError;
        }
    }

    // Iterate over mapping object b adding key-value pairs to dictionary a. b may be a dictionary
    // If override is true, existing pairs in a will be replaced if a matching key is found in b,
    // otherwise pairs will only be added if there is not a matching key in a.
    // Return 0 on success or -1 if an exception was raised.
    pub fn merge(self: *Dict, other: *Object, override: bool) !void {
        if (self.mergeUnchecked(other, override) < 0) {
            return error.PyError;
        }
    }

    // Calls PyDict_Merge(self, other, override) without error checking
    pub fn mergeUnchecked(self: *Dict, other: *Object, override: bool) c_int {
        return @ptrCast(c.PyDict_Merge(@ptrCast(self), @ptrCast(other), @intFromBool(override)));
    }

    // This is the same as merge(a, b, 1) in C, and is similar to a.update(b) in Python
    // except that PyDict_Update() doesn’t fall back to the iterating over a sequence of key
    // value pairs if the second argument has no “keys” attribute. Return 0 on success or -1
    // if an exception was raised.
    pub fn update(self: *Dict, other: *Object) !void {
        if (self.updateUnchecked(other) < 0) {
            return error.PyError;
        }
    }
    pub fn updateUnchecked(self: *Dict, other: *Object) c_int {
        return @ptrCast(c.PyDict_Update(@ptrCast(self), @ptrCast(other)));
    }

    // Empty an existing dictionary of all key-value pairs.
    pub fn clear(self: *Dict) void {
        c.PyDict_Clear(@ptrCast(self));
    }

    // Same as length but no error checking
    pub fn size(self: *Dict) isize {
        return c.PyDict_Size(@ptrCast(self));
    }

    // Iterate over all key-value pairs in the dictionary p. The Py_ssize_t referred to by ppos must be initialized to 0
    // prior to the first call to this function to start the iteration;
    // the function returns true for each pair in the dictionary, and false
    // once all pairs have been reported.
    pub fn next(self: *Dict, pos: *isize) ?Item {
        var item: Item = undefined;
        if (c.PyDict_Next(@ptrCast(self), pos, &item.key, &item.value)) {
            return item;
        }
        return null;
    }

};

pub const Set = extern struct {
    pub const BaseType = c.PySetObject;

    // The underlying python structure
    impl: BaseType,

    // Import the object protocol
    pub usingnamespace ObjectProtocol(@This());

};

pub const Module = extern struct {
    // https://docs.python.org/3/c-api/module.html
    // The underlying python structure
    impl: c.PyTypeObject,

    // Import the object protocol
    pub usingnamespace ObjectProtocol(@This());

    // Return true if p is a module object, or a subtype of a module object.
    // This function always succeeds.
    pub fn check(obj: *Object) bool {
        return c.PyModule_Check(@ptrCast(obj)) == 1;
    }

    // Return true if p is a module object, but not a subtype of PyModule_Type.
    // This function always succeeds.
    pub fn checkExact(obj: *Object) bool {
        return c.PyModule_CheckExact(@ptrCast(obj)) == 1;
    }

    // Add an object to module as name. This is a convenience function which can be used
    // from the module’s initialization function.
    // This does not steal a reference to value.
    pub fn addObjectRef(self: *Module, name: [:0]const u8, value: [*c]Object) !void {
        const r = c.PyModule_AddObjectRef(@ptrCast(self), name, @ptrCast(value));
        if (r < 0 ) return error.PyError;
    }

    // Like addObjectRef but steals a reference to value
    pub fn addObject(self: *Module, name: [:0]const u8, value: *Object) !void {
        const f = if (comptime versionCheck(.gte, VER_313)) c.PyModule_Add else c.PyModule_AddObject;
        const r = f(@ptrCast(self), name, @ptrCast(value));
        if (r < 0 ) return error.PyError;
    }

    pub fn create(def: *ModuleDef) [*c]Object {
        const mod = @as([*c]c.PyModuleDef, @ptrCast(def));
        return @ptrCast(c.PyModule_Create(mod));
    }

};

// Returns a new reference.
// const builtins = try py.importModule("builtins");
// defer builtins.decref();
pub fn importModule(name: [:0]const u8) !*Module {
    if (c.PyImport_ImportModule(@ptrCast(name))) |mod| {
        return @ptrCast(mod);
    }
    return error.PyError;
}


pub const MethodDef = c.PyMethodDef;
pub const GetSetDef = c.PyGetSetDef;
pub const SlotDef = c.PyModuleDef_Slot;

pub const ModuleDef = extern struct {
    const BaseType = c.PyModuleDef;
    const Self = @This();
    impl: BaseType,
    pub fn new(v: BaseType) Self {
        return Self{.impl=v};
    }

    pub fn init(self: *Self) ?*Object {
        return @ptrCast(c.PyModuleDef_Init(@ptrCast(self)));
    }
};


test "interpreter init" {
    initialize();
    defer finalize();

}
