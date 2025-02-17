import pytest
from atom import api as catom

from zatom import api as zatom

try:
    import pytest_benchmark  # noqa: F401

    BENCHMARK_INSTALLED = True
except ImportError:
    BENCHMARK_INSTALLED = False


@pytest.mark.skipif(not BENCHMARK_INSTALLED, reason="benchmark is not installed")
@pytest.mark.benchmark(group="init")
def test_create_small_obj_zatom(benchmark):
    class Point(zatom.Atom):
        x = zatom.Int()
        y = zatom.Int()
        z = zatom.Int()

    benchmark.pedantic(Point, rounds=100000, iterations=100)


@pytest.mark.skipif(not BENCHMARK_INSTALLED, reason="benchmark is not installed")
@pytest.mark.benchmark(group="init")
def test_create_small_obj_atom(benchmark):
    class Point(catom.Atom):
        x = catom.Int()
        y = catom.Int()
        z = catom.Int()

    benchmark.pedantic(Point, rounds=100000, iterations=100)


@pytest.mark.skipif(not BENCHMARK_INSTALLED, reason="benchmark is not installed")
@pytest.mark.benchmark(group="init")
def test_create_small_obj_slots(benchmark):
    class Point:
        __slots__ = ("x", "y", "z")

    benchmark.pedantic(Point, rounds=100000, iterations=100)
