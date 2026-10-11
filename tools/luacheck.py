"""Syntax-check Lua files with Lua 5.4 (via lupa). Usage: python luacheck.py file.lua ..."""
import sys
from lupa.lua54 import LuaRuntime

lua = LuaRuntime()
check = lua.eval("function(src, name) local f, err = load(src, '=' .. name) return err end")
bad = 0
for path in sys.argv[1:]:
    err = check(open(path, encoding="utf-8").read(), path)
    print(("FAIL " + err) if err else ("ok   " + path))
    bad += 1 if err else 0
sys.exit(1 if bad else 0)
