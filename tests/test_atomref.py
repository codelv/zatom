import gc
from zatom.api import Atom, Int, atomref


def test_atomref():
    class Pt(Atom):
        x = Int()
        y = Int()

    p = Pt()
    ref = atomref(p)
    assert bool(ref)
    assert ref() is p
    del p
    gc.collect()
    assert not bool(ref)
    assert ref() is None
