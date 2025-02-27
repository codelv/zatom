from zatom.api import Atom, Int

def test_atom_subclass():
    class A(Atom):
        a = Int()
        def foo(self):
            return self.a

    class B(A):
        b = Int()

    B.a.index = 0
    B.b.index = 1

    b = B(a=1)
    assert b.foo() == 1

    assert B.__slot_count__ == 2

    assert b.get_member("a") is not None
