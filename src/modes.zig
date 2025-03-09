const py = @import("py");

// Enum
pub const DefaultValue = enum(u8) {
    NoOp = 0,
    Static,
    List,
    Set,
    Dict,
    DefaultDict,
    NonOptional,
    Delegate,
    CallObject,
    CallObject_Object,
    CallObject_ObjectName,
    ObjectMethod,
    ObjectMethod_Name,
    MemberMethod_Object,
};

pub const Validate = enum(u8) {
    NoOp = 0,
    Bool,
    Int,
    IntPromote,
    Float,
    FloatPromote,
    Bytes,
    BytesPromote,
    Str,
    StrPromote,
    Tuple,
    FixedTuple,
    List,
    ContainerList,
    Set,
    Dict,
    DefaultDict,
    OptionalInstance,
    Instance,
    OptionalTyped,
    Typed,
    Subclass,
    Enum,
    Callable,
    FloatRange,
    FloatRangePromote,
    Range,
    Coerced,
    Delegate,
    ObjectMethod_OldNew,
    ObjectMethod_NameOldNew,
    MemberMethod_ObjectOldNew,
};

pub fn initModule(mod: *py.Module) !void {
    try mod.addObject("DefaultValue", try py.newIntEnum(DefaultValue));
    try mod.addObject("Validate", try py.newIntEnum(Validate));
}

pub fn deinitModule(mod: *py.Module) void {
    _ = mod;
}
