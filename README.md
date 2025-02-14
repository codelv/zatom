# hadron is a zig port of Atom

`hadron` is a drop in replacement of [Atom](https://github.com/nucleic/atom) that is rewritten in [zig](https://ziglang.org/).
using [py.zig](https://github.com/codelv/py.zig).

To use hadron, simply install it and replace any imports from `atom` to use `hadron`.

Some reasons why you might choose this over normal atom:

- Slightly faster initialization and member access. `zatom` leverages zig type generation and a metaclass 
to create and use types with inlined slots for up to 64 members (an arbitrary limit set). 
- Reduced memory usage. All inlined `zatom` objects are 16 bytes smaller than `zatom` counterparts.
- Certain members (Event & Signal) take no storage. All Bool members get bit-packed into a single slot.
- zatom's uses a custom allocator that uses `PyMem_*` so memory usage is properly tracked by tracemalloc and other tools.
- No C++ :).

