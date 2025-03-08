import gc
import weakref
import pytest
from zatom.api import (
    Atom,
    AtomMeta,
    Str,
    Value,
    Int,
    Bool,
    Enum,
    List,
    add_member,
    DefaultValue,
    set_default,
)


def test_atom_missing_attr():
    class A(Atom):
        id = Int()
        ok = Bool()

    a = A()
    with pytest.raises(AttributeError):
        a.foo


def test_atom_empty_no_slots():
    class A(Atom):
        pass

    assert A.__slot_count__ == 0
    a = A()
    assert a is not None


def test_atom_empty_with_slots():
    class A(Atom):
        __slots__ = ("x",)

    assert A.__slot_count__ == 0
    a = A()
    a.x = 1
    assert a.x == 1


def test_atom_one_member_no_slots():
    class A(Atom):
        x = Int()

    assert A.__slot_count__ == 1
    assert A.x.index == 0
    a = A()
    a.x = 1
    assert a.x == 1


def test_atom_one_member_with_slots():
    class A(Atom):
        __slots__ = ("y",)
        x = Int()

    assert A.__slot_count__ == 1
    assert A.x.index == 0
    a = A()
    a.x = 1
    a.y = 2
    assert a.x == 1
    assert a.y == 2


def test_atom_two_members_no_slots():
    class A(Atom):
        x = Int()
        y = Int()

    assert A.__slot_count__ == 2
    assert A.x.index == 0
    assert A.y.index == 1
    a = A()
    a.x = 1
    a.y = 2
    assert a.x == 1
    assert a.y == 2


def test_atom_two_members_with_slots():
    class A(Atom):
        __slots__ = ("x", "y")
        z = Int()
        a = Int()

    assert A.__slot_count__ == 2
    assert A.z.index == 0
    assert A.a.index == 1
    a = A()
    a.x = 1
    a.y = 2
    a.z = 3
    a.a = 4
    assert a.x == 1
    assert a.y == 2
    assert a.z == 3
    assert a.a == 4


def test_atom_subclass():
    class A(Atom):
        id = Int()

        def get_id(self):
            return self.id

    class B(A):
        name = Str()

    assert B.id.index == 1
    assert B.name.index == 0

    b = B(id=1)
    assert b.get_id() == 1
    assert b.name == ""

    assert len(B.__bases__) == 1
    assert B.__slot_count__ == 2

    assert b.get_member("name") is B.name
    # The member is cloned so is A.id won't work
    assert isinstance(b.get_member("id"), Int)


def test_atom_subclass_redef():
    class A(Atom):
        key = Int()
        name = Str("name")

    class B(A):
        key = Str("new")

    assert B.key.index == 0
    assert B.name.index == 1
    assert B.__slot_count__ == 2

    b = B()
    assert b.key == "new"
    assert b.name == "name"


def test_atom_subclass_packed():
    class A(Atom):
        enabled = Bool(True)
        name = Str("default")

    class B(A):
        activated = Bool()

    assert B.activated.index == 0
    assert B.enabled.index == 0
    assert B.name.index == 1
    assert B.__slot_count__ == 2

    b = B()
    assert b.enabled
    assert not b.activated
    assert b.name == "default"


def test_atom_subclass_increase_slots():
    class A(Atom):
        a = Str()
        b = Str()

    class B(A):
        c = Str()

    assert B.__slot_count__ == 3

    b = B()


def test_atom_weakrefs():
    class A(Atom, enable_weakrefs=True):
        a = Str()

    a = A()
    ref = weakref.ref(a)
    assert ref() is a
    del a
    gc.collect()
    assert ref() is None


def test_multiple_subclass():
    class Obj(Atom):
        id = Int()

    class Decl(Obj):
        activated = Bool()

    class Widget(Decl):
        widget = Value()

    class Stylable(Decl):
        style = Str()

    print(Widget.__mro__)
    print(Stylable.__mro__)

    class StylableWidget(Widget, Stylable):
        pass


def test_add_member_slot_storage():

    class A(Atom):  # type: ignore
        a = Int()

    assert A.__slot_count__ == 1
    b = Int()
    add_member(A, "b", b)
    assert A.__slot_count__ == 2
    assert A.get_member("b") is b

    a = A(a=1, b=2)
    assert a.a == 1
    assert a.b == 2


def test_add_member_static_storage():

    class A(Atom):  # type: ignore
        a = Bool()

    assert A.__slot_count__ == 1
    b = Bool()
    add_member(A, "b", b)
    assert A.__slot_count__ == 1
    assert A.get_member("b") is b

    a = A(a=True, b=False)
    assert a.a is True
    assert a.b is False


def test_set_default():

    class A(Atom):  # type: ignore
        name = Str("A")

    class B(A):
        name = set_default("B")

    a = A()
    assert a.name == "A"
    b = B()
    assert b.name == "B"


def test_atom_meta_subclass():
    class MyMeta(AtomMeta):
        def __new__(meta, name, bases, dct):
            cls = AtomMeta.__new__(meta, name, bases, dct)
            cls.__my_member__ = True
            return cls

    class A(Atom, metaclass=MyMeta):
        a = Int(1)
        b = Int(2)

    assert A.__my_member__ is True
    a = A()
    assert a.a == 1
    assert a.b == 2
