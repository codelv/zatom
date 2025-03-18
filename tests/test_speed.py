import pytest
from atom import api as catom
from zatom import api as zatom

pytest.importorskip("pytest_benchmark")

atoms = (catom, zatom)

@pytest.mark.parametrize("atom", (*atoms, "slots"))
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


@pytest.mark.parametrize("atom", (*atoms, "slots"))
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


@pytest.mark.parametrize("atom", (*atoms, "slots"))
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


@pytest.mark.parametrize("atom", (*atoms, "slots"))
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


@pytest.mark.parametrize("atom", (*atoms, "slots"))
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


@pytest.mark.parametrize("atom", atoms)
@pytest.mark.benchmark(group="validate-coerced")
def test_setattr_coerced(benchmark, atom):
    class Obj(atom.Atom):
        item = atom.Coerced(int, factory=lambda: 0)

    p = Obj()
    p.item

    def run():
        p.item = "1"

    benchmark.pedantic(run, rounds=10000, iterations=100)


@pytest.mark.parametrize("atom", atoms)
@pytest.mark.benchmark(group="validate-range")
def test_validate_range(benchmark, atom):
    class Obj(atom.Atom):
        item = atom.Range(low=0, high=10)

    p = Obj()
    i = 0
    p.item = 0

    def run():
        nonlocal i
        i += 1
        if i == 9:
            i = 0
        p.item = i

    benchmark.pedantic(run, rounds=10000, iterations=100)


@pytest.mark.parametrize("atom", atoms)
@pytest.mark.benchmark(group="validate-range-float")
def test_validate_range_float(benchmark, atom):
    class Obj(atom.Atom):
        item = atom.FloatRange(low=0, high=10)

    p = Obj()
    i = 0.0
    p.item = 0

    def run():
        nonlocal i
        i += 1.2
        if i > 9:
            i = 0
        p.item = i

    benchmark.pedantic(run, rounds=10000, iterations=100)


@pytest.mark.parametrize("atom", atoms)
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


@pytest.mark.parametrize("atom", atoms)
@pytest.mark.benchmark(group="validate-tuple")
def test_validate_tuple_str(benchmark, atom):
    class Obj(atom.Atom):
        items = atom.Tuple(atom.Str())

    obj = Obj()
    value = tuple(f"{i}" for i in range(100))
    with pytest.raises(TypeError):
        obj.items = (1, 2)  # Make sure its actually working

    def update():
        obj.items = value
        del obj.items

    benchmark.pedantic(update, rounds=100, iterations=10)


@pytest.mark.parametrize("atom", atoms)
@pytest.mark.benchmark(group="validate-list")
def test_validate_list_int(benchmark, atom):
    class Obj(atom.Atom):
        items = atom.List(atom.Int())

    obj = Obj()
    value = [i for i in range(100)]
    with pytest.raises(TypeError):
        obj.items = ["1"]  # Make sure its actually working

    def update():
        obj.items = value
        del obj.items

    benchmark.pedantic(update, rounds=100, iterations=10)


@pytest.mark.parametrize("atom", atoms)
@pytest.mark.benchmark(group="list-append")
def test_typed_list_append_int(benchmark, atom):
    if atom == "slots":

        class Obj:
            __slots__ = ("items",)

    else:

        class Obj(atom.Atom):
            items = atom.List(atom.Int())

    obj = Obj()
    obj.items = [0]
    if atom != "slots":
        with pytest.raises(TypeError):
            obj.items.append("1")  # Make sure its actually working

    i = 0

    def update():
        nonlocal i
        i += 1
        obj.items.append(i)

    benchmark.pedantic(update, rounds=1000, iterations=10)


@pytest.mark.parametrize("atom", (catom, zatom, "slots"))
@pytest.mark.benchmark(group="list-extend")
def test_typed_list_extend_int(benchmark, atom):
    if atom == "slots":

        class Obj:
            __slots__ = ("items",)

    else:

        class Obj(atom.Atom):
            items = atom.List(atom.Int())

    obj = Obj()
    obj.items = [0]

    if atom != "slots":
        with pytest.raises(TypeError):
            obj.items.extend(["1"])  # Make sure its actually working

    def update():
        obj.items.extend([1, 2, 3])

    benchmark.pedantic(update, rounds=100, iterations=10)


@pytest.mark.parametrize("atom", atoms)
@pytest.mark.benchmark(group="observer-decorated-notify")
def test_observer_decorated_notify(benchmark, atom):
    class Obj(atom.Atom):
        x = atom.Int()

        @atom.observe("x")
        def on_change(self, change):
            pass

    obj = Obj()

    def update():
        obj.x += 1

    benchmark.pedantic(update, rounds=1000, iterations=10)


@pytest.mark.parametrize("atom", atoms)
@pytest.mark.benchmark(group="observer-extended-notify")
def test_observer_decorated_notify(benchmark, atom):
    class Point(atom.Atom):
        x = atom.Int()

    class Obj(atom.Atom):
        pos = atom.Typed(Point, ())

        @atom.observe("pos.x")
        def on_change(self, change):
            pass

    obj = Obj()

    def update():
        obj.pos.x += 1
        if obj.pos.x == 100:
            obj.pos = Point()

    benchmark.pedantic(update, rounds=1000, iterations=10)


@pytest.mark.parametrize("atom", atoms)
@pytest.mark.benchmark(group="observer-static-notify")
def test_observer_static_notify(benchmark, atom):
    class Obj(atom.Atom):
        x = atom.Int()

    def observer(change):
        pass

    Obj.x.add_static_observer(observer)

    obj = Obj()

    def update():
        obj.x += 1

    benchmark.pedantic(update, rounds=1000, iterations=10)


@pytest.mark.parametrize("atom", atoms)
@pytest.mark.benchmark(group="observer-dynamic-notify")
def test_observer_dynamic_notify(benchmark, atom):
    class Obj(atom.Atom):
        x = atom.Int()

    def observer(change):
        pass

    obj = Obj()
    obj.observe("x", observer)

    def update():
        obj.x += 1

    benchmark.pedantic(update, rounds=1000, iterations=10)
