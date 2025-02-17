from sys import getsizeof

from zatom.api import Atom, Bool, Int


def test_bool_size():
    class A(Atom):
        # Bools get packed into a single slot
        a = Bool()
        b = Bool()
        c = Bool()
        d = Bool()

    a = A()
    assert getsizeof(a) == 48

    class B:
        __slots__ = ("a", "b", "c", "d")

    b = B()
    assert getsizeof(a) < getsizeof(b)
