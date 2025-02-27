import pytest
from zatom.api import Atom, Int, Typed, observe


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



def test_observe_decorator():
    changes = []

    class A(Atom):
        x = Int()

        @observe('x')
        def on_change(self, change):
            changes.append(change)

    assert A.x.has_observers()
    a = A()
    a.x
    assert len(changes) == 1
    assert changes[-1] == {"type": "create", "name": "x", "object": a, "value": 0}

    a.x = 1
    assert len(changes) == 2
    assert changes[-1] == {"type": "update", "name": "x", "object": a, "oldvalue": 0, "value": 1}

    del a.x
    assert len(changes) == 3
    assert changes[-1] == {"type": "delete", "name": "x", "object": a, "value": 1}

    with pytest.raises(AttributeError):
        class Pt(Atom):
            x = Int()

            @observe('missing')
            def on_change(self, change):
                pass

def test_observe_extended_decorator():
    changes = []

    class Pt(Atom):
        x = Int()

    class A(Atom):
        pos = Typed(Pt, ())

        @observe('pos.x')
        def on_change(self, change):
            changes.append(change)

    assert A.pos.has_observers()
    a = A()
    a.pos.x
    assert a.pos.has_observers('x')
    assert len(changes) == 1
    assert changes[-1] == {"type": "create", "name": "x", "object": a.pos, "value": 0}

    a.pos.x = 1
    assert len(changes) == 2
    assert changes[-1] == {"type": "update", "name": "x", "object": a.pos, "oldvalue": 0, "value": 1}

    del a.pos.x
    assert len(changes) == 3
    assert changes[-1] == {"type": "delete", "name": "x", "object": a.pos, "value": 1}

    # a.pos = Pt(x=2) FIXME
    a.pos = Pt()
    a.pos.x = 2
    assert len(changes) == 4
    assert changes[-1] == {"type": "create", "name": "x", "object": a.pos, "value": 2}

    with pytest.raises(AttributeError):
        class B(Atom):
            pos = Typed(Pt, ())

            @observe('pos.missing')
            def on_change(self, change):
                pass


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

