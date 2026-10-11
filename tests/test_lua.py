"""Offline checks for the UI Lua: every module compiles under LuaJIT (the game's
Lua) and the pure selection logic in model.lua behaves as specified."""

from pathlib import Path

import pytest
from lupa import luajit21

LUA_DIR = Path(__file__).resolve().parent.parent / "src" / "ui" / "promote_specialist"
LUA_FILES = sorted(LUA_DIR.glob("*.lua"))


def runtime():
    return luajit21.LuaRuntime(unpack_returned_tuples=True)


@pytest.mark.parametrize("path", LUA_FILES, ids=lambda p: p.name)
def test_compiles(path):
    compile_ = runtime().eval("function(s, n) local f, e = loadstring(s, n); return f ~= nil, e end")
    ok, err = compile_(path.read_text(encoding="utf-8"), path.name)
    assert ok, err


def test_ui_xml_lists_every_module():
    ui_xml = (LUA_DIR.parent.parent / "ui.xml").read_text(encoding="utf-8")
    for path in LUA_FILES:
        assert f'"ui/promote_specialist/{path.name}"' in ui_xml, path.name


@pytest.fixture
def model():
    lua = runtime()
    lua.execute((LUA_DIR / "model.lua").read_text(encoding="utf-8"))
    lua.execute(
        """
        function cand(skill, key, sameShip, sameSector, distance)
          return { skill = skill, key = key, sameShip = sameShip or false,
                   sameSector = sameSector or false, distance = distance or math.huge }
        end
        function list(...) return { ... } end
        """
    )
    return lua


def pick_key(lua, candidates, choice):
    result = lua.globals().PromoteSpecialist.model.pick(candidates, choice)
    return None if result is None else result.key


def test_stars_match_display_skill(model):
    stars = model.globals().PromoteSpecialist.model.stars
    # 0-100 -> floor(*15/100) -> floor(/3)
    assert [stars(s) for s in (0, 19, 20, 39, 40, 59, 60, 79, 80, 99, 100)] == [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5]


def test_counts_are_exact_buckets(model):
    g = model.globals()
    cands = model.eval('list(cand(100, "a"), cand(65, "b"), cand(62, "c"), cand(25, "d"), cand(5, "e"))')
    counts = g.PromoteSpecialist.model.counts(cands)
    assert counts.any == 5
    # e has 0 stars and only counts towards any
    assert [counts[n] for n in range(1, 6)] == [1, 0, 2, 0, 1]


def test_pick_exact_bucket_best_and_worst(model):
    cands = model.eval('list(cand(100, "a"), cand(65, "b"), cand(62, "c"), cand(25, "d"), cand(5, "e"))')
    assert pick_key(model, cands, "best") == "a"
    assert pick_key(model, cands, "worst") == "e"
    assert pick_key(model, cands, 3) == "c"
    assert pick_key(model, cands, 1) == "d"
    assert pick_key(model, cands, 5) == "a"
    assert pick_key(model, cands, 2) is None
    assert pick_key(model, cands, 4) is None


def test_sorted_and_pick_index(model):
    m = model.globals().PromoteSpecialist.model
    cands = model.eval(
        'list(cand(5, "w2", false, false), cand(62, "c"), cand(100, "a"), cand(5, "w1", true, true, 0))'
    )
    ordered = m.sorted(cands)
    assert [ordered[i].key for i in range(1, 5)] == ["a", "c", "w1", "w2"]
    # input list is left untouched
    assert cands[1].key == "w2"
    assert m.pickIndex(ordered, "best") == 1
    assert m.pickIndex(ordered, "worst") == 3
    assert m.pickIndex(ordered, 3) == 2
    assert m.pickIndex(model.eval("list()"), "worst") is None


def test_filter_exact_stars_keeps_order(model):
    m = model.globals().PromoteSpecialist.model
    ordered = m.sorted(model.eval('list(cand(5, "e"), cand(62, "c"), cand(100, "a"), cand(65, "b"))'))
    keys = lambda pool: [pool[i].key for i in range(1, len(pool) + 1)]
    assert keys(m.filter(ordered, "any")) == ["a", "b", "c", "e"]
    assert keys(m.filter(ordered, 3)) == ["b", "c"]
    assert keys(m.filter(ordered, 5)) == ["a"]
    assert keys(m.filter(ordered, 2)) == []


def test_index_of(model):
    m = model.globals().PromoteSpecialist.model
    cands = model.eval('list(cand(100, "a"), cand(65, "b"))')
    assert m.indexOf(cands, "b") == 2
    assert m.indexOf(cands, "zz") is None
    assert m.indexOf(cands, None) is None


def test_pick_ties_prefer_same_ship_then_sector_then_distance(model):
    cands = model.eval(
        'list(cand(62, "far", false, false), cand(62, "sector900", false, true, 900),'
        ' cand(62, "sector100", false, true, 100), cand(62, "aboard", true, true, 0))'
    )
    assert pick_key(model, cands, 3) == "aboard"
    assert pick_key(model, cands, "best") == "aboard"
    model.globals().table.remove(cands, 4)
    assert pick_key(model, cands, 3) == "sector100"


def test_pick_none(model):
    assert pick_key(model, model.eval("list()"), "best") is None
    assert pick_key(model, model.eval('list(cand(5, "q"))'), 1) is None
