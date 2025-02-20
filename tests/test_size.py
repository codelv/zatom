import pytest
from sys import getsizeof

from zatom.api import Atom, Bool, Int


def test_sizeof():
    class A(Atom):
        # Bools get packed into a single slot
        a = Bool()
        b = Bool()
        c = Bool()
        d = Bool()

    assert A.__slot_count__ == 1
    assert A.a.index == 0
    assert A.b.index == 0
    assert A.c.index == 0
    assert A.d.index == 0
    a = A()
    assert not hasattr(a, "__dict__")
    assert getsizeof(a) == 48

    class B:
        __slots__ = ("a", "b", "c", "d")

    b = B()
    assert getsizeof(a) < getsizeof(b)

    class C(Atom):
        x = Int()
        y = Int()

    c = C()
    assert getsizeof(c) == 56
