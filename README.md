# zatom is a zig port of Atom

`zatom` is an alternative to [Atom](https://github.com/nucleic/atom) that is rewritten in [zig](https://ziglang.org/).
using [py.zig](https://github.com/codelv/py.zig). 

It aims to be mostly backwards compatible but drops several rarely used features of atom 
that may be breaking depending on the usage (see below).  It is compatible with [enaml](https://github.com/nucleic/atom).

To use it, simply install it and replace any imports from `atom` to use `zatom` or alternatively
you can import `zatom` and call `zatom.install()` before any normal `atom` imports occur.


## Features

Some reasons why you might choose this over normal atom:

- Slightly faster initialization and member access. `zatom` leverages zig type generation and a metaclass 
to create and use types with inlined slots for up to 64 members (an arbitrary limit set). 
- Reduced memory usage.
- Certain members (`Event` and `Signal`) take no storage. 
- Some members (eg `Bool` and `Enum`) have `static` storage so multiple members can be bit-packed into a single slot.
- zatom's uses a custom allocator that uses `PyMem_*` so internal memory usage is properly tracked by tracemalloc and other tools.
- No C++ :).


#### Breaking changes

- Members in `zatom` have no runtime switchable validation modes. You cannot subclass a `Str` member and 
make it accept an `int` using a custom validate method. 
- The `__atom_members_` is a read-only dict proxy. Certain modifications to Atom classes are not allowed. For instance a member with static storage cannot be removed.
- `zatom` instances us a 32-bit index to a pool manager on their type object so each class can only have 2**32 observed instances.
- Due to their limited use, postgetattr and postsetattr modes are removed
- Members have no static observers, instead these static observers are defined on the atom's type object, the however old interface remains
