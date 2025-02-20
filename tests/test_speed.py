import pytest
from atom import api as catom
from zatom import api as zatom

pytest.importorskip("pytest_benchmark")


@pytest.mark.parametrize("atom", (catom, zatom, "slots"))
@pytest.mark.benchmark(group="init")
def test_create_small_obj(benchmark, atom):
    if atom == "slots":

        class Point:
            __slots__ = ("x", "y", "z")

    else:

        class Point(atom.Atom):
            x = atom.Int()
            y = atom.Int()
            z = atom.Int()

    benchmark.pedantic(Point, rounds=10000, iterations=100)


@pytest.mark.parametrize("atom", (catom, zatom, "slots"))
@pytest.mark.benchmark(group="getattr-int")
def test_getattr_int(benchmark, atom):
    if atom == "slots":

        class Point:
            __slots__ = ("x",)

    else:

        class Point(atom.Atom):
            x = atom.Int()

    p = Point()
    p.x = 1

    benchmark.pedantic(lambda: p.x, rounds=10000, iterations=100)


@pytest.mark.parametrize("atom", (catom, zatom, "slots"))
@pytest.mark.benchmark(group="getattr-bool")
def test_getattr_bool(benchmark, atom):
    if atom == "slots":

        class Obj:
            __slots__ = ("count", "ok")

    else:

        class Obj(atom.Atom):
            count = atom.Int()
            ok = atom.Bool()

    obj = Obj()
    obj.ok = True

    benchmark.pedantic(lambda: obj.ok, rounds=10000, iterations=100)


@pytest.mark.benchmark(group="getattr-int")
def test_getattr_int_property(benchmark):
    class Point:
        __slots__ = ("_x",)

        def _get_x(self):
            return self._x

        def _set_x(self, v):
            self._x = v

        x = property(_get_x, _set_x)

    p = Point()
    p.x = 1

    benchmark.pedantic(lambda: p.x, rounds=10000, iterations=100)


@pytest.mark.parametrize("atom", (catom, zatom, "slots"))
@pytest.mark.benchmark(group="setattr-int")
def test_setattr_int(benchmark, atom):
    if atom == "slots":

        class Point:
            __slots__ = ("x",)

    else:

        class Point(atom.Atom):
            x = atom.Int()

    p = Point()
    p.x = 0

    def add():
        p.x += 1

    benchmark.pedantic(add, rounds=10000, iterations=100)


@pytest.mark.parametrize("atom", (catom, zatom, "slots"))
@pytest.mark.benchmark(group="setattr-bool")
def test_setattr_bool(benchmark, atom):
    if atom == "slots":

        class Point:
            __slots__ = ("ok",)

    else:

        class Point(atom.Atom):
            ok = atom.Bool()

    p = Point()
    p.ok = True

    def add():
        p.ok = not p.ok

    benchmark.pedantic(add, rounds=10000, iterations=100)


@pytest.mark.parametrize("atom", (catom, zatom))
@pytest.mark.benchmark(group="validate-set")
def test_validate_set_int(benchmark, atom):
    class Obj(atom.Atom):
        items = atom.Set(atom.Int())

    obj = Obj()
    value = {i for i in range(1000)}
    with pytest.raises(TypeError):
        obj.items = {"1"}  # Make sure its actually working

    def update():
        obj.items = value
        del obj.items

    benchmark.pedantic(update, rounds=100, iterations=10)


@pytest.mark.parametrize("atom", (catom, zatom))
@pytest.mark.benchmark(group="validate-list")
def test_validate_list_int(benchmark, atom):
    class Obj(atom.Atom):
        items = atom.List(atom.Int())

    obj = Obj()
    value = [i for i in range(1000)]
    with pytest.raises(TypeError):
        obj.items = ["1"]  # Make sure its actually working

    def update():
        obj.items = value
        del obj.items

    benchmark.pedantic(update, rounds=100, iterations=10)
