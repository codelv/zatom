from zatom.api import Atom, Int


def test_observe():
    class A(Atom):
        x = Int()

    changes = []
    def observer(change):
        print(change)
        changes.append(change)

    a = A()
    a.observe('x', observer)
    a.x
    assert changes[-1] == {"type": "create", "name": "x", "object": a, "value": 0}
    a.x = 1
    assert changes[-1] == {"type": "update", "name": "x", "object": a, "oldvalue": 0, "value": 1}
    del a.x
    assert changes[-1] == {"type": "delete", "name": "x", "object": a, "value": 1}
    print(changes)
    assert len(changes) == 3
