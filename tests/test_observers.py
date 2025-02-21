from zatom.api import Atom, Int


def test_dynamic_observe():
    class A(Atom):
        x = Int()

    changes = []

    def observer(change):
        print(change)
        changes.append(change)

    a = A()
    assert not a.has_observers()
    assert not a.has_observers("x")
    assert not a.has_observer("x", observer)
    a.observe("x", observer)
    assert a.has_observers()
    assert a.has_observers("x")
    assert a.has_observer("x", observer)

    a.x
    assert changes[-1] == {"type": "create", "name": "x", "object": a, "value": 0}

    a.x = 1
    assert changes[-1] == {
        "type": "update",
        "name": "x",
        "object": a,
        "oldvalue": 0,
        "value": 1,
    }

    assert len(changes) == 2
    a.x = 1
    assert len(changes) == 2  # Setting same values does not trigger a change

    del a.x
    assert changes[-1] == {"type": "delete", "name": "x", "object": a, "value": 1}
    assert len(changes) == 3

    a.unobserve("x")
    assert not a.has_observer("x", observer)
    assert not a.has_observers("x")
    assert not a.has_observers()

    a.x = 3
    assert len(changes) == 3


def test_static_observe():
    class A(Atom):
        x = Int()

    changes = []

    def observer(change):
        print(change)
        changes.append(change)

    assert not A.x.has_observers()
    assert not A.x.has_observer(observer)

    A.x.add_static_observer(observer)

    assert A.x.has_observers()
    assert A.x.has_observer(observer)

    a = A()
    a.x
    assert len(changes) == 1
    assert changes[-1] == {"type": "create", "name": "x", "object": a, "value": 0}

