# TinShareLab Classroom

TinShareLab Classroom is a modified version of [Veyon](https://github.com/veyon/veyon) 4.11.4,
distributed under the same GNU GPL v2 license (see `COPYING`). Copyright of the original work
remains with Tobias Junghans / Veyon Solutions and the Veyon contributors.

Changes from Veyon, started 2026-11-04:

- WebAPI listens on the loopback interface only.
- WebAPI answers browser (CORS and preflight) requests only from `https://tinsharelab.com`
  and `https://www.tinsharelab.com`, and rejects other web origins.
- WebAPI default connection limit raised from 32 to 64.
- Installer renamed to TinShareLab Classroom. Internal program names, the service name and
  configuration paths stay the same as Veyon.
- Windows installer is built natively with MSYS2 (`.ci/windows/build-msys2.sh`).

## Using it with tinsharelab.com

On the teacher's machine, enable the WebAPI once as administrator, then restart the service:

    veyon-wcli config set WebAPI/HttpServerEnabled true
    veyon-wcli service restart
