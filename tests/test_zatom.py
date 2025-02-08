import pytest
from zatom.api import sum, AtomMeta, Member

def test_atom():
    assert sum(1,2) == 3
    with pytest.raises(TypeError):
        AtomMeta.get_member("foo")
