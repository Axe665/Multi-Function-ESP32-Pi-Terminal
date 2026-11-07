"""Minimal Python 3.12 compatibility shim for the removed stdlib imp module."""
import importlib.machinery
import importlib.util
import sys
import types

PY_SOURCE = 1
PY_COMPILED = 2
C_EXTENSION = 3
PKG_DIRECTORY = 5
C_BUILTIN = 6
PY_FROZEN = 7

def new_module(name):
    return types.ModuleType(name)

def load_source(name, pathname, file=None):
    if file is not None:
        try: file.close()
        except Exception: pass
    spec = importlib.util.spec_from_file_location(name, pathname)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load %s from %s" % (name, pathname))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

def find_module(name, path=None):
    spec = importlib.machinery.PathFinder.find_spec(name, path)
    if spec is None or spec.origin is None:
        raise ImportError("No module named %s" % name)
    f = open(spec.origin, 'rb') if spec.origin.endswith('.py') else None
    return (f, spec.origin, ('.py', 'rb', PY_SOURCE))

def load_module(name, file, filename, details):
    if file is not None:
        try: file.close()
        except Exception: pass
    return load_source(name, filename)

def get_suffixes():
    return [('.py', 'rb', PY_SOURCE)]
