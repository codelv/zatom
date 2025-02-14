from zatom.api import AtomMeta, Atom, Member, Value, Str, Int, Bool, Bytes, Float


def test_atom_no_members():
    class A(Atom):
        pass

    print(A.__bases__)
    assert A.__slot_count__ == 0
    a = A()
