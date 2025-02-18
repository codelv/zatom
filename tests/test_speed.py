import pytest
from atom import api as catom

from zatom import api as zatom

pytest.importorskip("pytest_benchmark")

@pytest.mark.benchmark(group="init")
def test_create_small_obj_zatom(benchmark):
    class Point(zatom.Atom):
        x = zatom.Int()
        y = zatom.Int()
        z = zatom.Int()

    benchmark.pedantic(Point, rounds=100000, iterations=100)


@pytest.mark.benchmark(group="init")
def test_create_small_obj_atom(benchmark):
    class Point(catom.Atom):
        x = catom.Int()
        y = catom.Int()
        z = catom.Int()

    benchmark.pedantic(Point, rounds=100000, iterations=100)


@pytest.mark.benchmark(group="init")
def test_create_small_obj_slots(benchmark):
    class Point:
        __slots__ = ("x", "y", "z")

    benchmark.pedantic(Point, rounds=100000, iterations=100)


@pytest.mark.benchmark(group="getattr")
def test_getattr_zatom(benchmark):
    class Point(zatom.Atom):
        x = zatom.Int()

    p = Point()
    p.x = 1

    benchmark.pedantic(lambda: p.x, rounds=100000, iterations=100)

@pytest.mark.benchmark(group="getattr")
def test_getattr_atom(benchmark):
    class Point(catom.Atom):
        x = catom.Int()

    p = Point()
    p.x = 1

    benchmark.pedantic(lambda: p.x, rounds=100000, iterations=100)

@pytest.mark.benchmark(group="getattr")
def test_getattr_slots(benchmark):
    class Point:
        __slots__ = ("x", )

    p = Point()
    p.x = 1

    benchmark.pedantic(lambda: p.x, rounds=100000, iterations=100)

@pytest.mark.benchmark(group="getattr")
def test_getattr_property(benchmark):
    class Point:
        __slots__ = ("_x",)
        def _get_x(self):
            return self._x

        def _set_x(self, v):
            self._x = v
        x = property(_get_x, _set_x)

    p = Point()
    p.x = 1

    benchmark.pedantic(lambda: p.x, rounds=100000, iterations=100)

@pytest.mark.benchmark(group="setattr")
def test_setattr_zatom(benchmark):
    class Point(zatom.Atom):
        x = zatom.Int()

    p = Point()

    def add():
        p.x += 1

    benchmark.pedantic(add, rounds=100000, iterations=100)

@pytest.mark.benchmark(group="setattr")
def test_setattr_atom(benchmark):
    class Point(catom.Atom):
        x = catom.Int()

    p = Point()

    def add():
        p.x += 1

    benchmark.pedantic(add, rounds=100000, iterations=100)

@pytest.mark.benchmark(group="setattr")
def test_setattr_slots(benchmark):
    class Point:
        __slots__ = ("x", )

    p = Point()
    p.x = 0

    def add():
        p.x += 1

    benchmark.pedantic(add, rounds=100000, iterations=100)
