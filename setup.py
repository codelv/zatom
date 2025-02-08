from setuptools import Extension, setup, find_packages


ext_modules = [
    Extension(
        'zatom.api',
        sources=[
            'src/api.zig'
        ],
        extra_compile_args=["-DOptimize=ReleaseSafe"]
    )
]

setup(
    name='zatom',
    version='1.0.0',
    python_requires='>=3.10',
    build_zig=True,
    ext_modules=ext_modules,
    setup_requires=['setuptools-zig'],
    packages=find_packages(),
)
