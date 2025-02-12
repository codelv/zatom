import pytest
from zatom.api import AtomMeta, Atom, Member


def test_atom():

    class A(Atom):
        pass
    print(A.__bases__)
    a = A()
    class B(Atom):
         m = Member()
    print(B.__bases__)
    assert B.m.index == 0
    assert "m" in B.__atom_members__

    b = B()
    B.m.set_slot(b, 1)
    assert B.m.get_slot(b) == 1

    class C(Atom):
         m1 = Member()
         m2 = Member()


    # with pytest.raises(TypeError):
    #     AtomMeta.get_member("foo")
    # assert False
