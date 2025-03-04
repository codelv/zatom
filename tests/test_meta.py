import ast
from zatom.api import Atom, Str, Int, Bool, Enum, List

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


def test_multiple_subclass():
    bases = (Atom,)

    class ASTNode(*bases):  # type: ignore
        lineno = Int(-1)
        col_offset = Int(-1)
        end_lineno = Int(-1)
        end_col_offset = Int(-1)

    class PragmaArg(Atom):
        kind = Enum("token", "number", "string")
        value = Str()

    class Pragma(ASTNode):
        command = Str()
        #arguments = List(PragmaArg)
        _fields = ("command", "arguments")


