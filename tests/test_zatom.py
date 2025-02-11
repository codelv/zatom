import pytest
from zatom.api import AtomMeta, Atom, Member


def test_atom():

    class A(Atom):
        pass
    class B(Atom):
        m = Member()
    assert type(A) is not type(B)

    with pytest.raises(TypeError):
        AtomMeta.get_member("foo")
    assert False
