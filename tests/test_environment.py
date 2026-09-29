import re
import shutil
import subprocess
import sys
import textwrap

import pytest


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=120, **kw)


def version_tuple(output):
    m = re.search(r"\d+(?:\.\d+)*", output)
    return tuple(int(x) for x in m.group(0).split(".")) if m else ()


def assert_min(output, minimum, label):
    got = version_tuple(output)
    assert got, f"could not parse version from: {output!r}"
    assert got >= minimum, f"{label} {got} < required {minimum}"


def test_gxx_version_and_cpp26_build(tmp_path):
    r = run(["/opt/gcc16/bin/g++", "--version"])
    assert r.returncode == 0
    assert_min(r.stdout, (16, 2), "g++")

    src = tmp_path / "cpp26.cpp"
    src.write_text(
        textwrap.dedent(
            """
            #include <print>
            int main() { std::println("cpp26-ok"); }
            """
        )
    )
    exe = tmp_path / "cpp26"
    r = run(["/opt/gcc16/bin/g++", "-std=c++26", str(src), "-o", str(exe)])
    assert r.returncode == 0, r.stderr
    r = run([str(exe)])
    assert r.returncode == 0, f"rc={r.returncode} stderr={r.stderr}"
    assert r.stdout.strip() == "cpp26-ok"


def test_cmake():
    r = run(["cmake", "--version"])
    assert r.returncode == 0
    assert_min(r.stdout, (4, 4), "cmake")


def test_ninja():
    r = run(["ninja", "--version"])
    assert r.returncode == 0
    assert_min(r.stdout, (1, 13), "ninja")


def test_conan():
    r = run(["conan", "--version"])
    assert r.returncode == 0
    assert_min(r.stdout, (2, 32), "conan")


def test_clangd():
    r = run(["clangd", "--version"])
    assert r.returncode == 0
    assert_min(r.stdout, (22,), "clangd")


@pytest.mark.parametrize("tool", ["git", "gdb", "valgrind"])
def test_system_tools(tool):
    assert shutil.which(tool), f"{tool} not on PATH"
    r = run([tool, "--version"])
    assert r.returncode == 0, r.stderr


def test_python_version():
    assert sys.version_info[:2] >= (3, 13), sys.version


def test_pybind11():
    import pybind11

    assert_min(pybind11.__version__, (3, 1), "pybind11")


def test_pyarrow():
    import pyarrow

    assert_min(pyarrow.__version__, (25,), "pyarrow")


def test_numpy():
    import numpy

    assert_min(numpy.__version__, (2, 5), "numpy")


def test_pybind11_end_to_end(tmp_path):
    inc = run([sys.executable, "-m", "pybind11", "--includes"])
    assert inc.returncode == 0, inc.stderr
    suffix = run([sys.executable, "-c",
                  "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX'))"])
    ext_suffix = suffix.stdout.strip()

    src = tmp_path / "mini.cpp"
    src.write_text(
        textwrap.dedent(
            """
            #include <pybind11/pybind11.h>
            int add(int a, int b) { return a + b; }
            PYBIND11_MODULE(mini, m) { m.def("add", &add); }
            """
        )
    )
    mod = tmp_path / f"mini{ext_suffix}"
    r = run(["/opt/gcc16/bin/g++", "-std=c++20", "-O0", "-shared", "-fPIC",
             *inc.stdout.split(), str(src), "-o", str(mod)])
    assert r.returncode == 0, r.stderr

    r = run([sys.executable, "-c", "import mini; print(mini.add(20, 22))"],
            cwd=tmp_path)
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "42"


needs_gpu = pytest.mark.skipif(
    run([sys.executable, "-c",
         "import torch; assert torch.cuda.is_available()"]).returncode != 0,
    reason="no CUDA device",
)


@needs_gpu
def test_torch_cuda():
    import torch

    assert_min(torch.__version__.split("+")[0], (2, 11), "torch")
    assert "sm_75" in torch.cuda.get_arch_list(), torch.cuda.get_arch_list()
    assert "2060" in torch.cuda.get_device_name(0)

    a = torch.randn(512, 512, device="cuda")
    b = torch.randn(512, 512, device="cuda")
    torch.cuda.synchronize()
    assert float((a @ b).sum()) != 0.0
