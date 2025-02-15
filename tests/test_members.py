import pytest
from zatom.api import (
    AtomMeta, Atom, Member, Value, Str, Int, Bool, Bytes, Float, Typed, Instance
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
    assert A.m.metadata['foo'] is True
    del A.m.metadata
    assert A.m.metadata is None
    A.m.metadata = {"bar": 1}
    assert A.m.metadata == {"bar": 1}
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
        z = Int(default=2)

    p = Pt()
    assert p.x == 0
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
    class A(Atom):
        name = Str()

    a = A()
    assert a.name == ""
    a.name = "1"
    assert a.name == "1"
    with pytest.raises(TypeError):
        a.name = 1


def test_bool():
    class A(Atom):
        a = Bool()
        b = Bool()

    assert A.a.index == 0
    assert A.a.bit == 0
    assert A.b.index == 0
    assert A.b.bit == 1
    a = A()

    assert a.a == False
    a.a = True
    assert a.a == True
    assert a.b == False
    assert a.a == True

    with pytest.raises(TypeError):
        a.a = "foo"


def test_float():
    class A(Atom):
        x = Float()
        y = Float()
        z = Float(1.0)

    a = A()
    assert a.x == 0.0
    a.x = 2.0
    assert a.x == 2.0
    assert a.y == 0.0
    assert a.z == 1.0

    with pytest.raises(TypeError):
        a.z = None

def test_instance():
    class A(Atom):
        name = Instance(str)
        required_name = Instance(str, optional=False)
        data = Instance(dict, None, {"x":1})
        cls = Instance((str, list), factory=lambda: "foo")

    a = A()
    assert a.name is None
    a.name = "ok"
    assert a.name == "ok"
    with pytest.raises(TypeError):
        a.name = 1

    with pytest.raises(TypeError):
        a.required_name # No defai;t

    a.required_name = "required"
    assert a.required_name == "required"

    assert a.data == {"x": 1}
    a.data = {"status": "ok"}
    assert a.data["status"] == "ok"
    with pytest.raises(TypeError):
        a.data = []

    my_list = [1,2,3]
    assert a.cls == "foo"
    a.cls = my_list
    assert a.cls == my_list
    a.cls = "str"
    assert a.cls == "str"
    with pytest.raises(TypeError):
        a.cls = {}


def test_typed():
    class A(Atom):
        name = Typed(str)

    a = A()
    a.name = "x"
    with pytest.raises(TypeError):
        a.name = 1

