.. _install_wheels_src:

Building Python Wheels for Multiple Virtual Environments
=========================================================

The usual way to install the Python interface, ``scripts/build_python.sh``
(invoked by ``update_openEMS.sh``), compiles the Cython extensions and installs
them straight into **one** virtual environment. Working in a second venv means
compiling them a second time.

``scripts/build_python_wheels.sh`` instead produces ordinary ``.whl`` files.
Compile once, then ``pip install`` the same wheels into as many virtual
environments as you like.

.. code-block:: console

    ./scripts/build_python_wheels.sh --cpp-install-dir ~/opt/openEMS

    # then, in any virtual environment:
    pip install wheelhouse/*.whl

No ``LD_LIBRARY_PATH`` is needed, and the C++ libraries are compiled only once.


How it works
------------

The wheels **reference** the C++ installation rather than bundling it. They
contain only the Cython glue modules; the shared libraries stay in
``<cpp-install-dir>/lib`` and are located at import time through an ELF
``RUNPATH`` baked into each extension module::

    ~/opt/openEMS/lib/libopenEMS.so     <- one copy on disk
            ^         ^         ^
        venvA/     venvB/     venvC/    <- each holds only the small glue .so

This is not a new mechanism. ``setup.py`` already passes the prefix given in
``CSXCAD_INSTALL_PATH`` / ``OPENEMS_INSTALL_PATH`` to ``runtime_library_dirs``,
which the linker turns into ``RUNPATH``. The installed ``libCSXCAD.so``,
``libopenEMS.so`` and ``libnf2ff.so`` already carry the same ``RUNPATH``, so
their own dependencies (fparser, VTK, HDF5, Boost, tinyxml) resolve too. The
script's job is to drive that build cleanly and prove the result works.

A useful consequence: because the libraries are referenced and not copied,
**rebuilding the C++ code is picked up by every venv immediately**, with no
reinstall.


Options
-------

.. code-block:: console

    --cpp-install-dir DIR   C++ install prefix to link against
                            (default: $HOME/opt/openEMS)
    --outdir DIR            where to write the .whl files
                            (default: <project>/wheelhouse)
    --no-scm                use the static fallback_version from pyproject.toml
                            instead of deriving a version from git
    --keep-build-venv       don't delete the temporary build venv on exit

By default the version is derived from git by ``setuptools_scm``, e.g.
``0.37.0rc1.post1.dev2+g7b051bb74``. That is usually what you want: the version
changes when the submodules move, so ``pip install`` actually replaces an older
wheel instead of considering it already satisfied.


Limitations
-----------

.. important::
  The wheels are tied to ``<cpp-install-dir>``. Moving or deleting that
  directory breaks every venv that installed them. They are also specific to
  the machine, the distribution, and the Python minor version (they are
  ``cp3XX`` wheels, not ``manylinux`` wheels), so they cannot be handed to
  someone else.

Rebuild the wheels after any ABI-breaking change to the C++ libraries.

Producing wheels that are portable across machines would require a
``manylinux`` build: an old-glibc Docker image plus ``auditwheel repair`` to
bundle the whole dependency closure. For openEMS that closure includes VTK,
which is not packaged in the manylinux base images and would have to be built
from source. That is a substantial undertaking, and it sacrifices the fast
edit-compile-run loop described above, so it is out of scope here.


Two pitfalls worth knowing
--------------------------

Both of these silently produce a wheel that *looks* fine and fails elsewhere.
The script handles them, but they are easy to hit when building wheels by hand.

``VIRTUAL_ENV`` leaks into the RUNPATH
   ``setup.py`` appends ``$VIRTUAL_ENV`` to ``runtime_library_dirs``. If the
   wheel is built from inside a virtual environment, that environment's path is
   baked into the shipped extension modules. The script unsets ``VIRTUAL_ENV``
   for the build itself.

``CSXCAD`` becomes a path dependency of ``openEMS``
   When building the openEMS wheel, ``setup.py`` checks whether ``CSXCAD`` is
   importable. If it is not, it records a dependency on the *source directory*::

       Requires-Dist: CSXCAD @ file://localhost/home/you/openEMS-Project/CSXCAD/python

   which pins the wheel to that checkout. The script builds CSXCAD first,
   installs it into the build environment, and only then builds openEMS with
   ``--no-build-isolation``, so the metadata records a plain
   ``Requires-Dist: CSXCAD``.


Verification
------------

The script does not trust the wheel it just built. It installs both wheels into
a throwaway virtual environment and uses ``ldd`` to check what the dynamic
loader *actually* resolves each library to, then imports both packages to catch
missing symbols that a clean ``ldd`` would not reveal.

.. note::
  The verification step deliberately unsets ``LD_LIBRARY_PATH``.
  ``LD_LIBRARY_PATH`` takes precedence over ``DT_RUNPATH``, so on a machine
  where ``<cpp-install-dir>/lib`` is already on ``LD_LIBRARY_PATH`` -- a common
  openEMS setup -- even a completely broken wheel would appear to load
  correctly. Unsetting it means the check tests the wheel rather than the
  ambient environment.

Not every extension links a C++ library: ``Utilities.pyx`` uses no CSXCAD
symbols, so the linker's ``--as-needed`` drops ``-lCSXCAD`` and the module ends
up needing nothing but libc. The check reports such modules as ``no C++ deps``
rather than treating them as failures.
