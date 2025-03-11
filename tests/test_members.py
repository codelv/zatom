import pytest

from zatom.api import (
    Atom,
    AtomMeta,
    Bool,
    Bytes,
    Coerced,
    Constant,
    Dict,
    Enum,
    Event,
    Float,
    FloatRange,
    List,
    TypedList,
    TypedSet,
    Instance,
    ForwardInstance,
    Int,
    Member,
    Property,
    Range,
    Str,
    Set,
    Tuple,
    Typed,
    ForwardTyped,
    Value,
)


def test_atom_no_members():
    class A(Atom):
        pass

    print(A.__bases__)
    assert A.__slot_count__ == 0
    a = A()


def test_atom_one_member():
    class B(Atom):
        m = Member()

    print(B.__bases__)
    assert B.__slot_count__ == 1

    assert B.m.index == 0
    assert "m" in B.__atom_members__
    assert B.get_member("m") is B.m
    assert len(B.members()) == 1

    b = B()
    B.m.set_slot(b, "x")
    assert B.m.get_slot(b) == "x"
    assert b.get_member("m") is B.m


def test_atom_two_members():
    class C(Atom):
        m1 = Member()
        m2 = Member()

    print(C.__bases__)
    assert issubclass(C, Atom)
    assert C.m1.index == 0
    assert C.m2.index == 1
    assert C.__slot_count__ == 2
    assert "m1" in C.__atom_members__


def test_atom_member_tag():
    class A(Atom):
        m = Member().tag(foo=True)

    assert A.m.metadata is not None
    assert A.m.metadata["foo"] is True
    A.m.metadata = {"bar": 1}
    assert A.m.metadata == {"bar": 1}
    del A.m.metadata
    assert A.m.metadata is None
    with pytest.raises(TypeError):
        A.m.metadata = 1


def test_member_invalid_index():
    class A(Atom):
        m = Int()

    A.m.index = 2
    a = A()
    with pytest.raises(AttributeError):
        a.m


def test_int():
    class Pt(Atom):
        x = Int()
        y = Int()

        def _default_y(self):
            return 3

        z = Int(default=2)

    p = Pt()
    assert p.x == 0
    assert p.y == 3
    p.y = 1
    assert p.y == 1
    assert p.z == 2
    p.z = 3
    assert p.z == 3

    # Make sure default is not modified
    p2 = Pt()
    assert p2.z == 2

    # Check validator
    with pytest.raises(TypeError):
        p.x = 1.0


def test_str():
    def new_memo():
        return "foo"

    class A(Atom):
        name = Str()
        memo = Str(factory=new_memo)

    a = A()
    assert a.name == ""
    a.name = "1"
    assert a.name == "1"

    assert a.memo == "foo"
    assert A.memo.default_value_mode[-1] is new_memo

    with pytest.raises(TypeError):
        a.name = 1


def test_bool():
    class A(Atom):
        a = Bool()
        b = Bool()

    assert A.a.index == 0
    assert A.a.bitsize == 1
    assert A.a.offset == 0
    assert A.b.index == 0
    assert A.b.offset == 2  # There is an extra bit for tracking "null"
    assert A.b.bitsize == 1
    a = A()

    assert a.a == False
    a.a = True
    assert a.a == True
    assert a.b == False
    assert a.a == True

    with pytest.raises(TypeError):
        a.a = "foo"


def test_bytes():
    class A(Atom):
        data = Bytes()

    a = A()
    assert a.data == b""
    a.data = b"123"
    assert a.data == b"123"
    with pytest.raises(TypeError):
        a.data = "123"


def test_float():
    class A(Atom):
        x = Float()
        y = Float(factory=lambda: 99.0)
        z = Float(1.0)

    a = A()
    assert a.x == 0.0
    a.x = 2.0
    assert a.x == 2.0
    assert a.y == 99.0
    a.y = 12.0
    assert a.y == 12.0
    del a.y
    assert a.y == 99.0
    assert a.z == 1.0

    with pytest.raises(TypeError):
        a.z = None


def test_instance():
    class A(Atom):
        name = Instance(str)
        required_name = Instance(str, optional=False)
        data = Instance(dict, None, {"x": 1})
        cls = Instance((str, list), factory=lambda: "foo")

    a = A()
    assert a.name is None
    a.name = "ok"
    assert a.name == "ok"
    with pytest.raises(TypeError):
        a.name = 1

    with pytest.raises(TypeError):
        a.required_name  # No defai;t

    a.required_name = "required"
    assert a.required_name == "required"

    assert a.data == {"x": 1}
    a.data = {"status": "ok"}
    assert a.data["status"] == "ok"
    with pytest.raises(TypeError):
        a.data = []

    my_list = [1, 2, 3]
    assert a.cls == "foo"
    a.cls = my_list
    assert a.cls == my_list
    a.cls = "str"
    assert a.cls == "str"
    with pytest.raises(TypeError):
        a.cls = {}


def test_forward_instance():
    class A(Atom):
        other = ForwardInstance(lambda: C, ())

    class B(Atom):
        name = Str()

    class C(Atom):
        bar = Str()

    a = A()
    assert type(a.other) == C
    with pytest.raises(TypeError):
        a.other = B()


def test_coerced():
    class A(Atom):
        count = Coerced(int, (9,))

    a = A()
    assert a.count == 9
    a.count = "1"
    assert a.count == 1

    with pytest.raises(ValueError):
        a.count = "x"

def test_coerced_subclass():
    class Size(Atom):
        x = Int()
        y = Int()
        def __init__(self, x: int=0, y: int=0):
            super().__init__(x=x, y=y)

    class A(Atom):
        size = Coerced(Size, (-1, -1))

    class B(A):
        checked = Bool()

        def _default_size(self):
            return Size(320, 240)


    b = B()
    assert b.size.x == 320
    assert b.size.y == 240

def test_typed():
    class A(Atom):
        name = Typed(str)

    a = A()
    a.name = "x"
    with pytest.raises(TypeError):
        a.name = 1


def test_forward_typed():
    class A(Atom):
        other = ForwardTyped(lambda: B, ())

    class B(Atom):
        name = Str()

    class C(Atom):
        name = Str()

    a = A()
    assert type(a.other) is B
    with pytest.raises(TypeError):
        a.other = C()


def test_tuple():
    class A(Atom):
        items = Tuple()
        names = Tuple(str)
        options = Tuple(int, default=(1,))

    a = A()
    assert a.items == ()
    a.items = (1, 2, 3)
    assert a.items == (1, 2, 3)
    a.names = ("1", "2")
    assert a.names == ("1", "2")
    with pytest.raises(TypeError):
        a.names = ["1", 2]
    with pytest.raises(TypeError):
        a.names = ("1", 2)
    assert a.options == (1,)


def test_enum():
    class A(Atom):
        option = Enum(1, 2, 3, 4, 5, default=3)
        alt = Enum("one", "two")
        other_alt = alt("two")  # Calling an enum creates a copy with a new default
        single = Enum("fixed")

    assert A.option.index == 0
    assert A.option.offset == 0
    assert A.option.bitsize == 3
    assert A.alt.index == 0
    assert A.alt.offset == 4
    assert A.alt.bitsize == 1

    a = A()
    assert a.option == 3
    a.option = 2
    assert a.option == 2
    assert a.alt == "one"
    assert a.other_alt == "two"
    A.alt.get_slot(a) == 0
    a.alt = "two"
    A.alt.get_slot(a) == 1
    assert a.alt == "two"
    assert a.option == 2

    with pytest.raises(ValueError):
        a.option = 6

    with pytest.raises(TypeError):
        A.alt("three")


def test_event():
    class A(Atom):
        activated = Event()
        clicked = Event(str)

    assert A.activated.index is None
    a = A()

    changes = []

    def observer(change):
        changes.append(change)

    a.activated.bind(observer)
    a.activated(1)
    assert changes[-1] == {
        "type": "event",
        "object": a,
        "name": "activated",
        "value": 1,
    }
    with pytest.raises(TypeError):
        a.activated(extra=True)
    with pytest.raises(TypeError):
        a.activated(1, 2)
    a.activated.unbind(observer)
    assert len(changes) == 1
    a.activated(2)
    assert len(changes) == 1

    a.clicked.bind(observer)
    a.clicked("right")
    assert len(changes) == 2
    assert changes[-1] == {
        "type": "event",
        "object": a,
        "name": "clicked",
        "value": "right",
    }

    with pytest.raises(TypeError):
        a.clicked(1)


def test_constant():
    class A(Atom):
        pwd = Constant("foobar")

    a = A()
    assert a.pwd == "foobar"
    with pytest.raises(TypeError):
        a.pwd = "new"
    assert a.pwd == "foobar"
    with pytest.raises(TypeError):
        del a.pwd
    assert a.pwd == "foobar"


def test_set():
    class A(Atom):
        a = Set()
        b = Set(Int())
        c = Set(str, default={"a", "b", "c"})

    a = A()
    assert a.a == set()
    assert type(a.a) is set
    a.a = {"a", 1, True}
    with pytest.raises(TypeError):
        a.b = {"a"}
    a.b = {1, 2, 3}
    assert type(a.b) is TypedSet
    assert a.b == {1, 2, 3}
    a.b.update({4})
    assert a.b == {1, 2, 3, 4}
    with pytest.raises(TypeError):
        a.b.add("2")  # not an int
    assert a.c == {"a", "b", "c"}
    a.c.add("d")
    with pytest.raises(TypeError):
        a.c.update({1, 2, 3})  # not a str
    assert a.c == {"a", "b", "c", "d"}
    del a.c
    assert a.c == {"a", "b", "c"}


def test_list():
    class A(Atom):
        a = List()
        b = List(Int())
        c = List(str, default=["a", "b", "c"])

    a = A()
    assert a.a == []
    assert type(a.a) is list
    a.b = [1, 2, 3]
    assert type(a.b) is TypedList
    a.b.append(4)
    with pytest.raises(TypeError):
        a.b.append("5")
    with pytest.raises(TypeError):
        a.b = [1, "2"]

    # Make sure default does not get modified
    assert a.c == ["a", "b", "c"]
    a.c.append("d")
    assert a.c == ["a", "b", "c", "d"]
    del a.c
    assert a.c == ["a", "b", "c"]

    with pytest.raises(TypeError):
        a.c = [1]
    with pytest.raises(TypeError):
        a.c.append(3)


def test_dict():
    class A(Atom):
        a = Dict(default={"a": "b"})
        b = Dict(str, Int())
        c = Dict(int, List(int), factory=lambda: {1: [2]})

    a = A()
    assert a.a == {"a": "b"}
    a.a["c"] = "d"
    assert a.a == {"a": "b", "c": "d"}
    del a.a
    assert a.a == {"a": "b"}

    with pytest.raises(TypeError):
        a.a = []

    # Child validators
    a.b = {"a": 1}
    with pytest.raises(TypeError):
        a.b = {"a": "2"}
    with pytest.raises(TypeError):
        a.b = {1: "2"}

    assert a.c == {1: [2]}
    a.c = {1: [1, 2]}

    with pytest.raises(TypeError):
        a.c[1].append("4")

    with pytest.raises(TypeError):
        a.c = {1: 2}


def test_property():
    class A(Atom):
        __slots__ = ("_x", "_y")

        def _get_x(self):
            return self._x

        def _set_x(self, v):
            self._x = v

        def _del_x(self):
            del self._x

        x = Property()
        y = Property(lambda self: self._y)

    assert not A.x.cached
    assert not A.y.cached
    a = A()
    a._x = 1
    assert a._x == 1
    a._y = 2
    assert a._y == 2
    assert a.y == 2
    assert a.x == 1
    a.x = 2
    assert a._x == 2
    assert a.x == 2
    del a.x
    assert not hasattr(a, "_x")
    a.x = 1
    assert a.x == 1


def test_range():
    class A(Atom):
        x = Range(low=1)
        y = Range(high=10)
        z = Range(value=2)
        a = Range()

    a = A()
    assert a.x == 1
    assert a.y == 10
    assert a.z == 2
    assert a.a == 0
    with pytest.raises(TypeError):
        a.x = "1"
    with pytest.raises(TypeError):
        a.a = 1.0

    a.x = 2
    with pytest.raises(ValueError):
        a.x = 0
    assert a.x == 2

    a.y = 9
    with pytest.raises(ValueError):
        a.y = 11
    assert a.y == 9

    a.z = 12
    assert a.z == 12


def test_float_range():
    class A(Atom):
        x = FloatRange(low=1)
        y = FloatRange(high=10.0, strict=True)
        z = FloatRange(value=2)
        a = FloatRange()

    a = A()
    assert a.x == 1
    assert a.y == 10.0
    assert a.z == 2
    assert a.a == 0
    with pytest.raises(TypeError):
        a.x = "1"

    a.x = 2
    with pytest.raises(ValueError):
        a.x = 0
    assert a.x == 2

    a.y = 9.0
    with pytest.raises(ValueError):
        a.y = 11.0
    assert a.y == 9.0
    with pytest.raises(TypeError):
        a.y = 8  # strict

    a.z = 12
    assert a.z == 12
